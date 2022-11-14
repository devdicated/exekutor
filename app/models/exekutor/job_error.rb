# frozen_string_literal: true
module Exekutor
  class JobError < BaseRecord
    belongs_to :job
  end
end