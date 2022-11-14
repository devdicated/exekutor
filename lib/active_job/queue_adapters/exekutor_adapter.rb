# frozen_string_literal: true
module ActiveJob
  module QueueAdapters
    class ExekutorAdapter < Exekutor::Queue
      alias enqueue push
      alias enqueue_at schedule_at
    end
  end
end