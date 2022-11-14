# frozen_string_literal: true
module Exekutor
  class BaseRecord < Exekutor.config.job_base_class
    self.abstract_class = true
  end
end