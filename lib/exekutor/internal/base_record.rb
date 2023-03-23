# frozen_string_literal: true

module Exekutor
  # @private
  module Internal
    # The base class for Exekutor active record classes
    class BaseRecord < Exekutor.config.base_record_class
      self.abstract_class = true
      self.table_name_prefix = "exekutor_"
    end
  end
end
