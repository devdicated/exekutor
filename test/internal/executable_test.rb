# frozen_string_literal: true

require_relative "../test_helper"

class ExecutableTest < Minitest::Test
  attr_reader :executable

  def setup
    super
    @executable = TestClass.new
  end

  def test_initial_state
    assert_equal :pending, executable.state
  end

  def test_invalid_state
    assert_raises(ArgumentError) { executable.send(:set_state, nil) }
    assert_raises(ArgumentError) { executable.send(:set_state, :invalid) }
  end

  def test_compare_and_set_state
    executable.send(:set_state, :pending)

    assert_equal :pending, executable.state
    executable.send(:compare_and_set_state, :pending, :started)

    assert_equal :started, executable.state

    executable.send(:compare_and_set_state, :pending, :stopped)

    assert_equal :started, executable.state
  end

  def test_running
    TestClass::STATES.each do |state|
      executable.send(:set_state, state)
      if state == :started
        assert executable.running?
      else
        refute executable.running?
      end
    end
  end

  def test_restart_delay
    # Delay starts out at 10 seconds
    assert_equal 0, executable.consecutive_errors.value
    assert_in_delta 10.seconds, executable.restart_delay

    # Delay is around 65 (+- 5%) seconds at the fifth attempt
    executable.consecutive_errors.value = 5

    assert_in_delta 65.seconds, executable.restart_delay, 7.seconds

    # Delay is capped at 10.minutes
    executable.consecutive_errors.value = 15

    assert_in_delta 10.minutes, executable.restart_delay

    executable.consecutive_errors.value = 50

    assert_in_delta 10.minutes, executable.restart_delay
  end

  def test_maximum_consecutive_errors
    executable.consecutive_errors.value = 150

    assert_in_delta 10.minutes, executable.restart_delay

    Exekutor.expects(:on_fatal_error).with(kind_of(SystemExit))

    executable.consecutive_errors.value = 151
    assert_raises(SystemExit) { executable.restart_delay }
  end

  class TestClass
    include ::Exekutor.const_get(:Internal)::Executable
  end
end
