# frozen_string_literal: true

class TestBaseModel
  include ActiveModel::Model
  mattr_accessor :abstract_class, :table_name_prefix
end

class ApplicationRecord < ActiveRecord::Base; end

class TestBaseRecord < ApplicationRecord; end
