class TestBaseModel
  include ActiveModel::Model
  mattr_accessor :abstract_class, :table_name_prefix
end

class TestBaseRecord < ActiveRecord::Base; end