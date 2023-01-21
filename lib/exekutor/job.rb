# frozen_string_literal: true

require_relative "internal/base_record"

module Exekutor
  # Active record instance for a job
  class Job < Internal::BaseRecord
    self.implicit_order_column = :enqueued_at

    belongs_to :worker, optional: true
    has_many :execution_errors, class_name: "JobError"

    enum status: { pending: "p", executing: "e", completed: "c", failed: "f", discarded: "d" }

    # Sets the status to pending and clears the assigned worker
    def release!
      update! status: "p", worker_id: nil
    end

    # Sets the status to pending, clears the assigned worker, and schedules execution at the indicated time.
    # @param at [Time] when the job should be executed
    def reschedule!(at: Time.current)
      update! status: "p", scheduled_at: at, worker_id: nil, runtime: nil
    end

    # Sets the status to discarded.
    def discard!
      update! status: "d"
    end
  end
end