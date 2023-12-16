# frozen_string_literal: true

require "rails_helper"
require "fixtures/test_jobs"
require "fixtures/active_record"

class TestSerializer
  def dump(_) end

  def load(str) end
end

class InvalidSerializer # rubocop:disable Lint/EmptyClass
end

# noinspection RubyInstanceMethodNamingConvention
class ConfigurationTest < Minitest::Test
  attr_accessor :config

  def setup
    super
    self.config = ::Exekutor::Configuration.new
    ::Exekutor.stubs(:config).returns(config)
  end

  def test_config_present
    ::Exekutor.unstub(:config)

    refute_nil ::Exekutor.config
  end

  def test_configure_with_arity
    ::Exekutor.configure { |config| config.default_queue_priority = 1234 }

    assert_equal 1234, Exekutor.config.default_queue_priority
  end

  def test_configure_without_arity
    ::Exekutor.configure { config.default_queue_priority = 1234 }

    assert_equal 1234, Exekutor.config.default_queue_priority
  end

  def test_configure_with_hash
    ::Exekutor.configure(default_queue_priority: 1234)

    assert_equal 1234, Exekutor.config.default_queue_priority
  end

  def test_configure_with_invalid_arg
    assert_raises(ArgumentError) { ::Exekutor.configure(:invalid_arg) }
  end

  def test_invalid_default_queue_priority
    assert_raises(::Exekutor::Configuration::Error) do
      config.default_queue_priority = 0
    end
    assert_raises(::Exekutor::Configuration::Error) do
      config.default_queue_priority = 32_768
    end
  end

  def test_default_queue_priority
    config.default_queue_priority = 1234

    mock_connection = mock
    mock_connection.expects(:exec_query).with(anything, anything, includes(1234), anything)
    Exekutor::Job.expects(:connection).returns(mock_connection)

    Exekutor::Queue.new.push(TestJobs::Simple.new)
  end

  def test_base_record_class_name
    config.base_record_class_name = "TestBaseRecord"

    assert_equal TestBaseRecord, config.base_record_class
  ensure
    # Reset back to the default value
    config.base_record_class_name = "ActiveRecord::Base"
  end

  def test_invalid_base_record_class_name
    config.base_record_class_name = "NonexistentBaseRecord"
    assert_raises(Exekutor::Configuration::Error) { config.base_record_class }
  ensure
    # Reset back to the default value
    config.base_record_class_name = "ActiveRecord::Base"
  end

  def test_default_base_record_class_loading_error
    config.base_record_class_name = "ActiveRecord::Base"
    Object.expects(:const_get).with("::ActiveRecord::Base").raises(LoadError, "Test")
    assert_raises(Exekutor::Configuration::Error, "Cannot find ActiveRecord, did you install and load the gem?") do
      config.base_record_class
    end
  end

  def test_json_serializer_string
    config.json_serializer = "TestSerializer"

    assert_kind_of TestSerializer, config.load_json_serializer
  ensure
    # Reset back to the default value
    config.json_serializer = "JSON"
  end

  def test_json_serializer_symbol
    config.json_serializer = :test_serializer

    assert_kind_of TestSerializer, config.load_json_serializer
  ensure
    # Reset back to the default value
    config.json_serializer = "JSON"
  end

  def test_json_serializer_type_proc
    config.json_serializer = -> { TestSerializer }

    serializer = config.load_json_serializer

    assert_kind_of TestSerializer, serializer
    # Ensure the result is cached
    assert_same serializer, config.load_json_serializer
  ensure
    # Reset back to the default value
    config.json_serializer = "JSON"
  end

  def test_nonexistent_json_serializer
    config.json_serializer = "NonexistentSerializer"
    assert_raises(Exekutor::Configuration::Error) { config.load_json_serializer }
  ensure
    # Reset back to the default value
    config.json_serializer = "JSON"
  end

  def test_invalid_json_serializer_class
    config.json_serializer = "InvalidSerializer"
    assert_raises(Exekutor::Configuration::Error) { config.load_json_serializer }
  ensure
    # Reset back to the default value
    config.json_serializer = "JSON"
  end

  def test_invalid_json_serializer_type
    assert_raises(Exekutor::Configuration::Error) { config.json_serializer = 1234 }
  ensure
    # Reset back to the default value
    config.json_serializer = "JSON"
  end

  def test_default_set_db_connection_name
    refute_predicate config, :set_db_connection_name?
  end

  def test_default_max_threads
    mock_config = mock
    mock_config.expects(:pool).returns(99)
    ::Exekutor.const_get(:Internal)::BaseRecord.expects(:connection_db_config).returns(mock_config)

    assert_equal 98, ::Exekutor::Configuration.new.max_execution_threads
  end

  def test_worker_options
    # Set to 99 so we don't use the connection pool size
    config.max_execution_threads = 99
    # Only ends up in worker config if explicitly sets
    config.set_db_connection_name = true

    expected = {
      min_threads: config.min_execution_threads,
      max_threads: config.max_execution_threads,
      max_thread_idletime: config.max_execution_thread_idletime,
      set_db_connection_name: config.set_db_connection_name?,
      enable_listener: config.enable_listener?,
      delete_completed_jobs: config.delete_completed_jobs?,
      delete_discarded_jobs: config.delete_discarded_jobs?,
      delete_failed_jobs: config.delete_failed_jobs?,
      polling_interval: config.polling_interval,
      polling_jitter: config.polling_jitter,
      status_server_handler: config.status_server_handler,
      status_server_port: config.status_server_port,
      healthcheck_timeout: config.healthcheck_timeout
    }

    assert_equal expected, config.worker_options
  end
end
