# frozen_string_literal: true

require_relative "executable"

module Exekutor
  # @private
  module Internal
    class Executor
      include Executable

      def initialize(config = {})
        super()
        max_threads = config[:max_threads] || default_max_threads

        @executor = ThreadPoolExecutor.new name: "exekutor-job",
                                           fallback_policy: :abort,
                                           min_threads: config[:min_threads] || 1,
                                           max_threads: max_threads,
                                           max_queue: max_threads
        @callbacks = {
          before_execute: Concurrent::Array.new,
          after_execute: Concurrent::Array.new
        }.freeze
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

      def before_execute(*args, &callback)
        @callbacks[:before_execute] << [callback, args]
      end

      def after_execute(*args, &callback)
        @callbacks[:after_execute] << [callback, args]
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

      def run_callbacks(type, job, *args)
        callbacks = @callbacks[type]
        callbacks&.each do |(callback, extra_args)|
          begin
            if callback.arity.positive?
              callback.call(job, *args, *extra_args)
            else
              callback.call
            end
          rescue StandardError => err
            Exekutor.print_error err, "[Executor] Callback error!"
          end
        end
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
