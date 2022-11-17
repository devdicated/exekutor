# frozen_string_literal: true
module Exekutor
  module Info
    class Worker < BaseRecord
      self.implicit_order_column = :started_at
      enum status: { initializing: "i", running: "r", shutting_down: "s", crashed: "c" }

      def heartbeat!
        now = Time.now.change(sec: 0)
        touch :last_heartbeat_at, time: now if now >= self.last_heartbeat_at + 1.minute
      end
    end
  end
end