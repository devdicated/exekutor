# frozen_string_literal: true

require_relative "executable"
require_relative "callbacks"

module Exekutor
  # @private
  module Internal
    # Executes jobs from a thread pool
    class Executor
      include Executable, Callbacks, Logger

      define_callbacks :after_execute, freeze: true
      attr_reader :pending_job_updates

      def initialize(min_threads: 1, max_threads: default_max_threads, max_thread_idletime: 60,
                     delete_completed_jobs: false, delete_discarded_jobs: false, delete_failed_jobs: false)
        super()
        @executor = ThreadPoolExecutor.new name: "exekutor-job", fallback_policy: :abort, max_queue: max_threads,
                                           min_threads: min_threads, max_threads: max_threads,
                                           idletime: max_thread_idletime
        @active_job_ids = Concurrent::Array.new
        @pending_job_updates = Concurrent::Hash.new
        @options = {
          delete_completed_jobs: delete_completed_jobs,
          delete_discarded_jobs: delete_discarded_jobs,
          delete_failed_jobs: delete_failed_jobs
        }.freeze
      end

      # Starts the executor
      def start
        set_state :started
      end

      # Stops the executor
      def stop
        set_state :stopped

        @executor.shutdown
      end

      # Kills the executor
      def kill
        Thread.new { compare_and_set_state :started, :killed }
        @executor.kill
      end

      # Executes the job on one of the execution threads. Releases the job if there is no thread available to execute
      # the job.
      def post(job)
        @executor.post job, &method(:execute)
      rescue Concurrent::RejectedExecutionError
        logger.error "Ran out of threads! Releasing job #{job[:id]}"
        update_job job, status: "p", worker_id: nil
      end

      # The number of available threads to execute jobs on. Returns 0 if the executor is not running.
      def available_workers
        if @executor.running?
          @executor.available_threads
        else
          0
        end
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

      def _execute(job, start_time: Concurrent.monotonic_time)
        raise Exekutor::DiscardJob, "Maximum queue time expired" if queue_time_expired?(job)

        if (timeout = job[:options] && job[:options]["execution_timeout"]).present?
          Timeout.timeout Float(timeout), JobExecutionTimeout do
            ActiveJob::Base.execute(job[:payload])
          end
        else
          ActiveJob::Base.execute(job[:payload])
        end

        on_job_completed(job, runtime: Concurrent.monotonic_time - start_time)
      rescue StandardError, JobExecutionTimeout => e
        on_job_failed(job, e, runtime: Concurrent.monotonic_time - start_time)
      rescue Exception # rubocop:disable Lint/RescueException
        # Try to release job when an Exception occurs
        update_job job, status: "p", worker_id: nil
        raise
      end

      def on_job_completed(job, runtime:)
        if @options[:delete_completed_jobs]
          delete_job job
        else
          update_job job, status: "c", runtime: runtime
        end
      end

      def on_job_failed(job, error, runtime:)
        discarded = [Exekutor::DiscardJob, JobExecutionTimeout].any?(&error.method(:is_a?))
        unless discarded
          Internal::Hooks.on(:job_failure, job, error)
          log_error error, "Job failed"
        end

        if lost_db_connection?(error)
          # Try to release job
          update_job job, status: "p", worker_id: nil

        elsif @options[discarded ? :delete_discarded_jobs : :delete_failed_jobs]
          delete_job job

        else
          # Try to update the job and create a JobError record if update succeeds
          if update_job job, status: discarded ? "d" : "f", runtime: runtime
            JobError.create!(job_id: job[:id], error: error)
          end
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
            elsif old.present?
              old.merge!(new)
            else
              new
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

      def queue_time_expired?(job)
        job[:options] && job[:options]["start_execution_before"] &&
          job[:options]["start_execution_before"].to_f <= Time.now.to_f
      end

      def lost_db_connection?(error)
        [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].any?(&error.method(:is_a?)) &&
          !ActiveRecord::Base.connection.active?
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
      class JobExecutionTimeout < Exception; end # rubocop:disable Lint/InheritException
    end
  end
end
