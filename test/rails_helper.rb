# frozen_string_literal: true

require_relative "test_helper"

require "combustion"
Combustion.path = "test/rails_engine"
Combustion.initialize! :active_record, :active_job do
  config.active_job.queue_adapter = :exekutor
end
