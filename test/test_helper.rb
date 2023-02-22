# frozen_string_literal: true

require "bundler/setup"
require 'simplecov'
SimpleCov.start do
  add_filter "/test/"
end

require "minitest/autorun"
require "minitest/pride"
require "minitest/reporters"

require 'mocha/minitest'

require "rails/all"
Bundler.require :default

Minitest::Reporters.use! unless ENV['RM_INFO']
