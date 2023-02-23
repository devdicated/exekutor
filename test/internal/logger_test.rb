# frozen_string_literal: true

require_relative "../test_helper"

class LoggerTest < Minitest::Test
  attr_reader :loggable, :logger

  def setup
    super
    @loggable = TestClass.new
    @logger = ActiveSupport::Logger.new($stdout)
    ::Exekutor.stubs(:logger).returns(@logger)
  end

  def test_log_tags
    assert_equal ["TestClass"], loggable.log_tags
  end

  def test_logger
    logger.expects(:tagged).with(["TestClass"]).returns(logger)
    assert_same logger, loggable.send(:logger)
    # Call twice to ensure the logger is cached
    loggable.send(:logger)
  end

  def test_log_error
    ActiveSupport::BacktraceCleaner.any_instance.expects(:clean).returns(%w[line1 line2 line3])
    logger.stubs(:tagged).returns(logger)

    logger.expects(:error).with("log message")
    logger.expects(:error).with(all_of(includes("StandardError"), includes("error message"),
                                       includes("line1"), includes("line2"), includes("line3")))

    loggable.send(:log_error, StandardError.new("error message"), "log message")
  end

  def test_say
    ::Exekutor.config.expects(:quiet?).returns(false)
    assert_output("test 1\n") { ::Exekutor.say("test 1") }
  end

  def test_quiet_say
    ::Exekutor.config.expects(:quiet?).returns(true)
    assert_output("") { ::Exekutor.say("test 2") }
  end

  def test_print_error
    ::Exekutor.config.expects(:quiet?).returns(false)
    ActiveSupport::BacktraceCleaner.any_instance.expects(:clean).returns(%w[line1 line2 line3])

    $stderr.expects(:puts).with(includes("log message"))
    $stderr.expects(:puts).with(all_of(includes("StandardError"), includes("error message"),
                                       includes("line1"), includes("line2"), includes("line3")))

    logger.expects(:error).with("log message")
    logger.expects(:error).with(all_of(includes("StandardError"), includes("error message"),
                                       includes("line1"), includes("line2"), includes("line3")))

    ActiveSupport::Logger.expects(:logger_outputs_to?).with(logger, $stdout).returns(false)

    Exekutor.print_error StandardError.new("error message"), "log message"
  end

  def test_print_error_with_stdout_logger
    # Dont log to STDERR
    ::Exekutor.config.expects(:quiet?).returns(true)
    ActiveSupport::BacktraceCleaner.any_instance.expects(:clean).returns(%w[line1 line2 line3])

    ActiveSupport::Logger.expects(:logger_outputs_to?).with(logger, $stdout).returns(true)
    logger.expects(:error).never

    Exekutor.print_error StandardError.new("error message"), "log message"
  end

  def test_print_error_quietly
    ::Exekutor.config.expects(:quiet?).returns(true)
    ActiveSupport::BacktraceCleaner.any_instance.expects(:clean).returns(%w[line1 line2 line3])

    $stderr.expects(:puts).never

    Exekutor.print_error StandardError.new("error message"), "log message"
  end

  def test_set_untagged_logger
    logger = ActiveSupport::Logger.new($stdout)
    ActiveSupport::TaggedLogging.expects(:new).with(logger).returns(logger)
    Exekutor.logger = logger
  ensure
    ActiveSupport::TaggedLogging.unstub(:new)
    Exekutor.logger = ActiveSupport::Logger.new($stdout)
  end

  def test_set_tagged_logger
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))
    ActiveSupport::TaggedLogging.expects(:new).never
    Exekutor.logger = logger
  ensure
    ActiveSupport::TaggedLogging.unstub(:new)
    Exekutor.logger = ActiveSupport::Logger.new($stdout)
  end

  class TestClass
    include ::Exekutor.const_get(:Internal)::Logger
  end
end
