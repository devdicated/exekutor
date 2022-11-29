# frozen_string_literal: true
module Exekutor
  class BaseRecord < Exekutor.config.base_record_class
    self.abstract_class = true
  end
end