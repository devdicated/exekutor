# frozen_string_literal: true
module Exekutor
  module Info
    class Worker < BaseRecord
      self.implicit_order_column = :started_at
      enum status: { initializing: "i", running: "r", shutting_down: "s", crashed: "c" }
    end
  end
end