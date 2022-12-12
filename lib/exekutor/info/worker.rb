# frozen_string_literal: true

require_relative "../internal/base_record"

module Exekutor
  module Info
    class Worker < Internal::BaseRecord
      self.implicit_order_column = :started_at
      enum status: { initializing: "i", running: "r", shutting_down: "s", crashed: "c" }

      def heartbeat!
        now = Time.now.change(sec: 0)
        touch :last_heartbeat_at, time: now if self.last_heartbeat_at.nil? || now >= self.last_heartbeat_at + 1.minute
      end
    end
  end
end