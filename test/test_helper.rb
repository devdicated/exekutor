# frozen_string_literal: true

require "bundler/setup"

require "minitest/autorun"
# require "minitest/pride"
require "minitest/reporters"

require "rails/all"
Bundler.require :default

Minitest::Reporters.use! unless ENV['RM_INFO']
