# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../lib/exekutor/internal/cli/manager"

# noinspection RubyInstanceMethodNamingConvention
class ConfigLoaderTest < Minitest::Test
  FIXTURE_DIRECTORY = File.expand_path("#{File.dirname(__FILE__)}/../fixtures").freeze

  def test_yaml_configuration
    worker_options = {}
    loader = ::Exekutor.const_get(:Internal)::CLI::Manager::ConfigLoader.new(
      "#{FIXTURE_DIRECTORY}/configuration.yaml", {}
    )
    loader.load_config(worker_options)

    assert_configuration({
                           queues: %w[queues to watch],
                           min_threads: 7,
                           max_threads: 23,
                           min_priority: 719,
                           max_priority: 5039,
                           max_thread_idletime: 61.seconds,
                           enable_listener: true,
                           polling_interval: 37.seconds,
                           polling_jitter: 0.127,
                           status_server_port: 7919,
                           status_server_handler: "rack-handler",
                           healthcheck_timeout: 181.minutes,
                           set_db_connection_name: false,
                           wait_for_termination: 97.seconds
                         }, worker_options, Exekutor.config)
  end

  def test_yaml_override_configuration
    worker_options = {}
    loader = ::Exekutor.const_get(:Internal)::CLI::Manager::ConfigLoader.new(
      %W[#{FIXTURE_DIRECTORY}/configuration.yaml #{FIXTURE_DIRECTORY}/configuration.overrides.yaml], {}
    )
    loader.load_config(worker_options)

    assert_configuration({
                           queues: "override",
                           min_threads: 8,
                           max_threads: 24,
                           min_priority: 720,
                           max_priority: 5040,
                           max_thread_idletime: 62.seconds,
                           wait_for_termination: 98.seconds,
                           enable_listener: true,
                           polling_interval: 38.seconds,
                           polling_jitter: 0.128,
                           status_server_port: 7920,
                           status_server_handler: "another-rack-handler",
                           healthcheck_timeout: 182.minutes
                         }, worker_options, Exekutor.config)
  end

  private

  def assert_configuration(expected, worker_options, global_configuration)
    expected_worker_options = expected.slice(
      *::Exekutor.const_get(:Internal)::CLI::Manager::ConfigLoader.const_get(:WORKER_OPTIONS)
    )
    expected_global_options = expected.without(
      *::Exekutor.const_get(:Internal)::CLI::Manager::ConfigLoader.const_get(:WORKER_OPTIONS)
    )
    actual_global_options = expected_global_options.keys.index_with do |option|
      if option == :enable_listener
        global_configuration.send("#{option}?")
      else
        global_configuration.send(option)
      end
    end

    assert_equal(expected_worker_options, worker_options)
    assert_equal(expected_global_options, actual_global_options)
  end
end
