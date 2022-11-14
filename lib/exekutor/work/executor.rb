# frozen_string_literal: true
module Exekutor
  module Work
    class Executor

      def initialize(config = {})
        @executor = ThreadPoolExecutor.new name: 'exekutor-job',
                                           fallback_policy: :abort,
                                           min_threads: config[:min_threads] || 1,
                                           max_threads: config[:max_threads] || 10,
                                           max_queue: config[:max_threads] || 10
        @callbacks = {
          before_execute: Concurrent::Array.new,
          after_execute: Concurrent::Array.new
        }.freeze
      end

      def shutdown
        @executor.shutdown
      end

      def before_execute(&callback)
        @callbacks[:before_execute] << callback
      end

      def after_execute(&callback)
        @callbacks[:after_execute] << callback
      end

      def post(job)
        @executor.post job, &method(:execute)
      rescue Concurrent::RejectedExecutionError
        update_job job, status: "p", worker_id: nil
      end

      def available_threads
        if @executor.running?
          @executor.ready_worker_count
        else
          0
        end
      end

      private

      def execute(job)
        Rails.application.reloader.wrap do
          run_callbacks :before_execute, job
          start_time = Concurrent.monotonic_time
          begin
            ActiveJob::Base.execute(job[:payload])
            update_job job, status: "c", runtime: Concurrent.monotonic_time - start_time
            run_callbacks :after_completion, job
          rescue StandardError => ex
            update_job job, status: "f", runtime: Concurrent.monotonic_time - start_time
            JobError.create!(job_id: job[:id], error: ex)
            run_callbacks :after_failure, job, ex
          end
          run_callbacks :after_execute, job
        end
      end

      def update_job(job, **attrs)
        Exekutor::Job.where(id: job[:id]).update_all(attrs)
      end

      def run_callbacks(type, job, *args)
        callbacks = @callbacks[type]
        callbacks&.each do |callback|
          if callback.arity.positive?
            callback.call(job, *args)
          else
            callback.call
          end
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
