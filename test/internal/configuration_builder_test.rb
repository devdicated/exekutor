# frozen_string_literal: true

require_relative "../test_helper"

class BasicConfig
  include ::Exekutor.const_get(:Internal)::ConfigurationBuilder
  define_option :string_option, required: true
  define_option :integer_option, default: -> { 123 }, type: Integer, range: 1...999
  define_option :enum_option, default: :one, type: Symbol, enum: %i[one two three]

  def error_class
    Error
  end

  class Error < StandardError; end
end

class InvalidConfig
  include ::Exekutor.const_get(:Internal)::ConfigurationBuilder
  define_option :string_option, required: true
end

# noinspection RubyInstanceMethodNamingConvention
class ConfigurationBuilderTest < Minitest::Test
  attr_accessor :config

  def before_setup
    super
    self.config = BasicConfig.new
  end

  def test_batch_set
    config.set(string_option: "string", integer_option: 567, enum_option: :three)
    assert_equal "string", config.string_option
    assert_equal 567, config.integer_option
    assert_equal :three, config.enum_option
  end

  def test_invalid_batch_set
    assert_raises(BasicConfig::Error) { config.set(invalid: true) }
  end

  def test_required_option_error
    assert_raises(BasicConfig::Error) { config.string_option = "" }
  end

  def test_option_type_error
    assert_raises(BasicConfig::Error) { config.integer_option = "123" }
  end

  def test_range_option_inclusion_error
    assert_raises(BasicConfig::Error) { config.integer_option = 10_000 }
  end

  def test_enum_option_inclusion_error
    assert_raises(BasicConfig::Error) { config.enum_option = :four }
  end

  def test_invalid_config
    assert_raises("Implementing class should override #error_class") { InvalidConfig.new.string_option = nil }
  end
end
