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

      def initialize(min_threads: 1, max_threads: default_max_threads, max_thread_idletime: 60)
        super()
        @executor = ThreadPoolExecutor.new name: "exekutor-job", fallback_policy: :abort, max_queue: max_threads,
                                           min_threads: min_threads, max_threads: max_threads,
                                           idletime: max_thread_idletime
        @active_job_ids = Concurrent::Array.new
        @pending_job_updates = Concurrent::Hash.new
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

      def pending_job_updates
        @pending_job_updates
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
            start_time = Concurrent.monotonic_time
            begin
              if job[:options] && job[:options]["start_execution_before"] &&
                job[:options]["start_execution_before"].to_f <= Time.now.to_f
                raise Exekutor::DiscardJob.new("Maximum queue time expired")
              end
              if job[:options] && job[:options]["execution_timeout"].present?
                Timeout::timeout job[:options]["execution_timeout"].to_f, Exekutor::DiscardJob do
                  ActiveJob::Base.execute(job[:payload])
                end
              else
                ActiveJob::Base.execute(job[:payload])
              end
              update_job job, status: "c", runtime: Concurrent.monotonic_time - start_time
            rescue StandardError, Exekutor::DiscardJob => e
              discarded = e.is_a?(Exekutor::DiscardJob)
              log_error e, "Job failed" unless discarded

              if [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].any?(&e.method(:is_a?)) &&
                !ActiveRecord::Base.connection.active?
                # We lost the DB connection, try to release job
                update_job job, status: "p", worker_id: nil
              else
                Internal::Hooks.on(:job_failure, job, e) unless discarded

                if update_job job, status: discarded ? "d" : "f",
                              runtime: Concurrent.monotonic_time - start_time
                  JobError.create!(job_id: job[:id], error: e)
                end
              end
            rescue Exception
              # Release job when an Exception occurs
              update_job job, status: "p", worker_id: nil
              raise
            end
            # Run internal callbacks
            run_callbacks :after, :execute, job
          end
        end
      ensure
        @active_job_ids.delete(job[:id])
      end

      # Updates the active record entity for this job with the given attributes.
      def update_job(job, **attrs)
        Exekutor::Job.where(id: job[:id]).update_all(attrs)
        true
      rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
        unless Exekutor::Job.connection.active?
          log_error e, "Could not update job"
          # Save the update for when the connection is back
          @pending_job_updates.merge!(job[:id] => attrs) { |_k, old, new| old.present? ? old.merge!(new) : new }
        end
        false
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

    end
  end
end
