# frozen_string_literal: true
module Exekutor
  module Work
    module Providers
      class PollingProvider

        def initialize(interval:, reserver:, executor:)
          @reserver = reserver
          @executor = executor
          @task = Concurrent::TimerTask.new(execution_interval: interval, &method(:poll))
        end

        def start
          @task.execute
        end

        def stop
          @task.shutdown
        end

        private

        def poll(_task)
          jobs = @reserver.reserve @executor.available_threads
          jobs&.each(&@executor.method(:post))
          jobs&.size.to_i
        rescue StandardError => e
          puts "Polling Biem! #{e}"
        end

      end
    end
  end
end
