# frozen_string_literal: true
require "active_job"
require "active_job/queue_adapters"

module ActiveJob
  module QueueAdapters
    # The active job queue adapter for Exekutor
    class ExekutorAdapter < Exekutor::Queue
      alias enqueue push
      alias enqueue_all push
      alias enqueue_at schedule_at
    end
  end
end