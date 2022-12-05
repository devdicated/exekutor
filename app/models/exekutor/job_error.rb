# frozen_string_literal: true
module Exekutor
  class JobError < BaseRecord
    self.implicit_order_column = :created_at
    belongs_to :job
  end
end