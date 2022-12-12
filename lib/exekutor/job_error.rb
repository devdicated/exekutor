# frozen_string_literal: true

require_relative "internal/base_record"

module Exekutor
  class JobError < Internal::BaseRecord
    self.implicit_order_column = :created_at
    belongs_to :job
  end
end