# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../fixtures/mock/appsignal"

class AppsignalPluginTest < Minitest::Test
  attr_reader :mock_hooks

  def setup
    super
    # Make sure the plugin doesn't end up in any of the other tests
    @mock_hooks = ::Exekutor.const_get(:Internal)::Hooks.new
    ::Exekutor.stubs(:hooks).returns(@mock_hooks)

    # Use #load_plugin to define the plugin for the first test. Use #register for consecutive tests.
    if defined?(Exekutor::Plugins::Appsignal)
      @mock_hooks.register Exekutor::Plugins::Appsignal
    else
      ::Exekutor.load_plugin :appsignal
    end
  end

  def test_before_shutdown
    ::Appsignal.expects(:stop).with("exekutor")
    @mock_hooks.send(:run_callbacks, :before, :shutdown, mock)
  end

  def test_around_execution
    scheduled_at = Time.current
    ::Appsignal.expects(:monitor_transaction)
               .with("perform_job.exekutor", has_entries(method: "perform", queue_start: scheduled_at))
               .yields
    job = { id: :testid, options: {}, payload: {}, scheduled_at: scheduled_at }

    callable = mock
    callable.expects(:forward).with(job)
    @mock_hooks.send(:with_callbacks, :job_execution, job) do |*args|
      callable.forward(*args)
    end
  end

  def test_fatal_error
    ::Appsignal.expects(:add_exception).with(kind_of(StandardError))
    # Don't print the error to STDOUT
    ::Exekutor.config.stubs(:quiet?).returns(true)
    begin
      raise StandardError, "test"
    rescue StandardError => e
      ::Exekutor.on_fatal_error e
    end
  end
end
