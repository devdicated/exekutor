# frozen_string_literal: true

require "test_helper"

class ExekutorTest < Minitest::Test
  def test_version_set
    refute_nil ::Exekutor::VERSION
  end

  # TODO probably move all these to configuration_test.rb
  def test_config_present
    refute_nil ::Exekutor.config
  end

  def test_configure_with_arity
    ::Exekutor.configure { |config| config.default_queue_name = __method__.to_s }
    assert_equal __method__.to_s, Exekutor.config.default_queue_name
  end

  def test_configure_without_arity
    ::Exekutor.configure { config.default_queue_name = __method__.to_s }
    assert_equal __method__.to_s, Exekutor.config.default_queue_name
  end
end
