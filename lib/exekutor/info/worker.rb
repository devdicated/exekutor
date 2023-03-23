# frozen_string_literal: true

require_relative "../internal/base_record"

module Exekutor
  # Module for the Worker active record class
  module Info
    # Active record class for a worker instance
    class Worker < Internal::BaseRecord
      self.implicit_order_column = :started_at
      enum status: { initializing: "i", running: "r", shutting_down: "s", crashed: "c" }

      # Registers a heartbeat for this worker, if necessary
      def heartbeat!
        now = Time.now.change(sec: 0)
        touch :last_heartbeat_at, time: now if self.last_heartbeat_at.nil? || now >= self.last_heartbeat_at + 1.minute
      end
    end
  end
end
