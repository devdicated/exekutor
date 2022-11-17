# frozen_string_literal: true
require 'exekutor/executable'

module Exekutor
  module Work
    module Providers
      class PollingProvider
        include Executable

        def initialize(interval:, reserver:, executor:, pool:, interval_jitter: interval > 1 ? interval * 0.1 : 0)
          super()
          @interval = interval.to_f
          @interval_jitter = interval_jitter.to_f
          @reserver = reserver
          @executor = executor
          @pool = pool
        end

        def start
          return false unless compare_and_set_state :pending, :started

          schedule_next_task
          true
        end

        def stop
          set_state :stopped
          @task&.cancel
        end

        private

        def schedule_next_task(at: nil)
          return false unless running?

          @task.cancel if @task&.pending?

          delay = if at
                    at - Time.now
                  else
                    @interval + random_jitter
                  end
          @task = Concurrent::ScheduledTask.execute(delay, executor: @pool, &method(:poll))
        end

        def random_jitter
          return 0.0 if @interval_jitter.zero?

          (Kernel.rand - 0.5) * @interval_jitter
        end

        def poll
          return unless running?

          jobs = @reserver.reserve @executor.available_threads
          jobs&.each(&@executor.method(:post))
          jobs&.size.to_i
        rescue StandardError => e
          puts "Polling Biem! #{e}"
        ensure
          # TODO crash if too many failures
          schedule_next_task
        end
      end
    end
  end
end
