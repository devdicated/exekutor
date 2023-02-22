require_relative "test_helper"

require "combustion"
Combustion.path = "test/rails_engine"
Combustion.initialize! :active_record, :active_job
