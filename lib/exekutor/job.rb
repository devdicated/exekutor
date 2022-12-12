# frozen_string_literal: true

require_relative "internal/base_record"

module Exekutor
  class Job < Internal::BaseRecord
    self.implicit_order_column = :enqueued_at

    belongs_to :job, optional: true
    has_many :execution_errors, class_name: "JobError"

    enum status: { pending: "p", executing: "e", completed: "c", failed: "f", discarded: "d" }

    def release!
      update! status: "p", worker_id: nil
    end

    def reschedule!
      update! status: "p", scheduled_at: Time.now, worker_id: nil, runtime: nil
    end

    def discard!
      update! status: "d"
    end
  end
end