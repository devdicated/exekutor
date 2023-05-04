# frozen_string_literal: true

require_relative "executable"
require_relative "callbacks"

module Exekutor
  # @private
  module Internal
    # Executes jobs from a thread pool
    class Executor
      include Logger
      include Callbacks
      include Executable

      define_callbacks :after_execute, freeze: true
      attr_reader :pending_job_updates

      # rubocop:disable Metrics/ParameterLists

      # Create a new executor
      # @param min_threads [Integer] the minimum number of threads that should be active
      # @param max_threads [Integer] the maximum number of threads that may be active
      # @param max_thread_idletime [Integer] the amount of seconds a thread may be idle before being reclaimed
      # @param delete_completed_jobs [Boolean] whether to delete jobs that complete successfully
      # @param delete_discarded_jobs [Boolean] whether to delete jobs that are discarded
      # @param delete_failed_jobs [Boolean] whether to delete jobs that fail
      def initialize(min_threads: 1, max_threads: default_max_threads, max_thread_idletime: 180,
                     delete_completed_jobs: false, delete_discarded_jobs: false, delete_failed_jobs: false)
        super()
        @executor = ThreadPoolExecutor.new name: "exekutor-job", fallback_policy: :abort, max_queue: max_threads,
                                           min_threads: min_threads, max_threads: max_threads,
                                           idletime: max_thread_idletime
        @queued_job_ids = Concurrent::Array.new
        @active_job_ids = Concurrent::Array.new
        @pending_job_updates = Concurrent::Hash.new
        @options = {
          delete_completed_jobs: delete_completed_jobs,
          delete_discarded_jobs: delete_discarded_jobs,
          delete_failed_jobs: delete_failed_jobs
        }.freeze
      end

      # rubocop:enable Metrics/ParameterLists

      # Starts the executor
      def start
        self.state = :started
      end

      # Stops the executor
      def stop
        self.state = :stopped

        @executor.shutdown
      end

      # Kills the executor
      def kill
        Thread.new { compare_and_set_state :started, :killed }
        @executor.kill

        release_assigned_jobs
      end

      # Executes the job on one of the execution threads. Releases the job if there is no thread available to execute
      # the job.
      def post(job)
        @executor.post(job) { |*args| execute(*args) }
        @queued_job_ids.append(job[:id])
      rescue Concurrent::RejectedExecutionError
        logger.error "Ran out of threads! Releasing job #{job[:id]}"
        update_job job, status: "p", worker_id: nil
      end

      # @return [Integer] the number of available threads to execute jobs on. Returns 0 if the executor is not running.
      def available_threads
        if @executor.running?
          @executor.available_threads
        else
          0
        end
      end

      # @return [Integer] the minimum number of threads to execute jobs on.
      def minimum_threads
        @executor.min_length
      end

      # @return [Integer] the maximum number of threads to execute jobs on.
      def maximum_threads
        @executor.max_length
      end

      # @return [Array<String>] The ids of the jobs that are currently being executed
      def active_job_ids
        @active_job_ids.dup.to_a
      end

      # Prunes the inactive threads from the pool.
      def prune_pool
        @executor.prune_pool
      end

      private

      # Executes the given job
      def execute(job)
        @queued_job_ids.delete(job[:id])
        @active_job_ids.append(job[:id])
        Rails.application.reloader.wrap do
          DatabaseConnection.ensure_active!
          Internal::Hooks.run :job_execution, job do
            _execute(job)
            # Run internal callbacks
            run_callbacks :after, :execute, job
          end
        end
      ensure
        @active_job_ids.delete(job[:id])
      end

      def _execute(job, start_time: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        raise Exekutor::DiscardJob, "Maximum queue time expired" if queue_time_expired?(job)

        with_job_execution_timeout job.dig(:options, "execution_timeout") do
          ActiveJob::Base.execute(job[:payload])
        end

        on_job_completed(job, runtime: Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time)
      rescue StandardError, JobExecutionTimeout => e
        on_job_failed(job, e, runtime: Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time)
      rescue Exception # rubocop:disable Lint/RescueException
        # Try to release job when an Exception occurs
        update_job job, status: "p", worker_id: nil
        raise
      end

      def on_job_completed(job, runtime:)
        next_status = "c"
        if delete_job? next_status
          delete_job job
        else
          update_job job, status: next_status, runtime: runtime
        end
      end

      def on_job_failed(job, error, runtime:)
        discarded = [Exekutor::DiscardJob, JobExecutionTimeout].any? { |c| error.is_a? c }
        next_status = discarded ? "d" : "f"
        unless discarded
          Internal::Hooks.on(:job_failure, job, error)
          log_error error, "Job failed"
        end

        if lost_db_connection?(error)
          # Don't consider this as a failure, try again later.
          update_job job, status: "p", worker_id: nil

        elsif delete_job? next_status
          delete_job job

          # Try to update the job and create a JobError record if update succeeds
        elsif update_job job, status: next_status, runtime: runtime
          JobError.create(job_id: job[:id], error: error)
        end
      end

      def delete_job?(next_status)
        case next_status
        when "c"
          @options[:delete_completed_jobs]
        when "d"
          @options[:delete_discarded_jobs]
        when "f"
          @options[:delete_failed_jobs]
        else
          false
        end
      end

      # Updates the active record entity for this job with the given attributes.
      def update_job(job, **attrs)
        Exekutor::Job.where(id: job[:id]).update_all(attrs)
        true
      rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
        unless Exekutor::Job.connection.active?
          log_error e, "Could not update job"
          # Save the update for when the connection is back
          @pending_job_updates.merge!(job[:id] => attrs) do |_k, old, new|
            if old == :destroy
              old
            else
              old&.merge!(new) || new
            end
          end
        end
        false
      end

      def delete_job(job)
        Exekutor::Job.destroy(job[:id])
        true
      rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
        unless Exekutor::Job.connection.active?
          log_error e, "Could not delete job"
          # Save the deletion for when the connection is back
          @pending_job_updates[job[:id]] = :destroy
        end
        false
      end

      def release_assigned_jobs
        @queued_job_ids.each { |id| update_job({ id: id }, status: "p", worker_id: nil) }
        @active_job_ids.each { |id| update_job({ id: id }, status: "p", worker_id: nil) }
      end

      def queue_time_expired?(job)
        job[:options] && job[:options]["start_execution_before"] &&
          job[:options]["start_execution_before"].to_f <= Time.now.to_f
      end

      def with_job_execution_timeout(timeout, &block)
        if timeout
          Timeout.timeout Float(timeout), JobExecutionTimeout, &block
        else
          yield
        end
      end

      def lost_db_connection?(error)
        [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].any? do |error_class|
          error.is_a? error_class
        end && !ActiveRecord::Base.connection.active?
      end

      # The default maximum number of threads. The value is equal to the size of the DB connection pool minus 1, with
      # a minimum of 1.
      def default_max_threads
        connection_pool_size = Exekutor::Job.connection_db_config.pool
        if connection_pool_size && connection_pool_size > 2
          connection_pool_size - 1
        else
          1
        end
      end

      # The thread pool to use for executing jobs.
      class ThreadPoolExecutor < Concurrent::ThreadPoolExecutor
        # Number of inactive threads available to execute tasks.
        # https://github.com/ruby-concurrency/concurrent-ruby/issues/684#issuecomment-427594437
        # @return [Integer]
        def available_threads
          synchronize do
            if Concurrent.on_jruby?
              @executor.getMaximumPoolSize - @executor.getActiveCount
            else
              workers_still_to_be_created = @max_length - @pool.length
              workers_created_but_waiting = @ready.length
              workers_still_to_be_created + workers_created_but_waiting
            end
          end
        end
      end

      # Thrown when the job execution timeout expires. Inherits from Exception so it's less likely to be caught by
      # rescue statements.
      class JobExecutionTimeout < Exception # rubocop:disable Lint/InheritException
      end
    end
  end
end
