# frozen_string_literal: true
module Exekutor
  module Work
    module Providers
      class ScheduledProvider

        def initialize(delay:, reserver:, worker:, executor: nil)
          @reserver = reserver
          @worker = worker
          @task = Concurrent::ScheduledTask.new(delay, executor: executor, &method(:run))
        end

        def pending?
          @task.pending?
        end

        def reschedule(delay)
          scheduled_at = Time.now.to_f + delay
          return unless scheduled_at < @task.schedule_time

          @task.reschedule scheduled_at.to_f - Time.now.to_f
        end

        def start
          @task.execute
        end

        def stop
          @task.shutdown
        end

        def run(_task)
          jobs = @reserver.reserve(@worker.available_threads)
          jobs&.each { |job| @worker.post job }
        end
      end
    end
  end
end
