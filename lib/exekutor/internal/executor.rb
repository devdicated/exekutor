# frozen_string_literal: true

require_relative "executable"
require_relative "callbacks"

module Exekutor
  # @private
  module Internal
    class Executor
      include Executable
      include Callbacks

      define_callbacks :before_execute, :after_execute, :after_completion, :after_failure, freeze: true

      def initialize(min_threads: 1, max_threads: default_max_threads, max_thread_idletime: 60)
        super()
        @executor = ThreadPoolExecutor.new name: "exekutor-job", fallback_policy: :abort, max_queue: max_threads,
                                           min_threads: min_threads, max_threads: max_threads,
                                           idletime: max_thread_idletime
      end

      def start
        set_state :started
      end

      def stop
        set_state :stopped

        @executor.shutdown
      end

      def kill
        Thread.new { compare_and_set_state :started, :killed }
        @executor.kill
      end

      def post(job)
        @executor.post job, &method(:execute)
      rescue Concurrent::RejectedExecutionError
        Exekutor.say "Ran out of threads! Releasing job #{job[:id]}"
        update_job job, status: "p", worker_id: nil
      end

      def available_threads
        if @executor.running?
          @executor.ready_worker_count
        else
          0
        end
      end

      def prune_pool
        @executor.prune_pool
      end

      private

      def execute(job)
        Rails.application.reloader.wrap do
          run_callbacks :before_execute, job
          start_time = Concurrent.monotonic_time
          begin
            if job[:options] && job[:options]["start_execution_before"] &&
              job[:options]["start_execution_before"].to_f <= Time.now.to_f
              raise Exekutor::DiscardJob.new("Maximum queue time expired")
            end
            if job[:options] && job[:options]["execution_timeout"].present?
              puts "tiomeout @#{job[:options]['execution_timeout']}"
              Timeout::timeout job[:options]["execution_timeout"].to_f, Exekutor::DiscardJob do
                puts "twst"
                ActiveJob::Base.execute(job[:payload])
              end
            else
              ActiveJob::Base.execute(job[:payload])
            end
            update_job job, status: "c", runtime: Concurrent.monotonic_time - start_time
            run_callbacks :after_completion, job
          rescue StandardError, Exekutor::DiscardJob => e
            update_job job, status: e.is_a?(Exekutor::DiscardJob) ? "d" : "f",
                       runtime: Concurrent.monotonic_time - start_time
            JobError.create!(job_id: job[:id], error: e)
            run_callbacks :after_failure, job, e
          end
          run_callbacks :after_execute, job
        end
      end

      def update_job(job, **attrs)
        Exekutor::Job.where(id: job[:id]).update_all(attrs)
      end

      def default_max_threads
        connection_pool_size = Exekutor::Job.connection_db_config.pool
        if connection_pool_size && connection_pool_size > 2
          connection_pool_size - 1
        else
          1
        end
      end

      class ThreadPoolExecutor < Concurrent::ThreadPoolExecutor
        # Number of inactive threads available to execute tasks.
        # https://github.com/ruby-concurrency/concurrent-ruby/issues/684#issuecomment-427594437
        # @return [Integer]
        def ready_worker_count
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
