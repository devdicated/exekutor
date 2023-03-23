# frozen_string_literal: true

require_relative "../test_helper"

class TestCallbacks
  include ::Exekutor.const_get(:Internal)::Callbacks

  define_callbacks :on_event, :before_another_event, :around_another_event, :after_another_event, freeze: false

  def emit_event(arg)
    run_callbacks :on, :event, arg
  end

  def emit_another_event(arg, &block)
    with_callbacks :another_event, arg, &block
  end
end

# noinspection RubyInstanceMethodNamingConvention
class CallbacksTest < Minitest::Test
  attr_accessor :callbacks

  def before_setup
    super
    self.callbacks = TestCallbacks.new
  end

  def test_callback_names
    assert_equal %i[on_event before_another_event around_another_event after_another_event],
                 callbacks.send(:__callback_names)
  end

  def test_define_invalid_callback
    assert_raises(TestCallbacks::Error) { TestCallbacks.define_callbacks :invalid_name }
  end

  def test_define_with_frozen_callbacks
    temp_callbacks = Class.new do
      include ::Exekutor.const_get(:Internal)::Callbacks
      define_callbacks :on_valid_event_name
    end
    assert_raises(TestCallbacks::Error) { temp_callbacks.define_callbacks :on_another_valid_event_name }
  end

  def test_add_callback
    callback = -> {}
    callbacks.add_callback :on_event, "arg2", &callback

    assert_includes(callbacks.send(:__callbacks)[:on_event], [callback, ["arg2"]])
  end

  def test_add_invalid_callback
    callback = -> {}
    assert_raises(TestCallbacks::Error) { callbacks.add_callback :invalid, "arg2", &callback }
  end

  def test_on_callback_with_args
    asserter = mock
    asserter.expects(:before).with("arg1", "arg2")
    asserter.expects(:around).with("arg1", "arg2").yields
    asserter.expects(:after).with("arg1", "arg2")
    asserter.expects(:yield_event).with("arg1")

    callbacks.add_callback :before_another_event, "arg2", &asserter.method(:before)
    callbacks.add_callback :around_another_event, "arg2", &asserter.method(:around)
    callbacks.add_callback :before_another_event, "arg2", &asserter.method(:after)

    callbacks.emit_another_event "arg1" do |*args|
      asserter.yield_event(*args)
    end
  end

  def test_chained_around_callbacks
    order = sequence("callbacks")
    asserter = mock
    asserter.expects(:around3).with("arg", "arg3").yields.in_sequence(order)
    asserter.expects(:around2).with("arg", "arg2").yields.in_sequence(order)
    asserter.expects(:around1).with("arg", "arg1").yields.in_sequence(order)
    asserter.expects(:yield_event).with("arg")

    callbacks.add_callback :around_another_event, "arg1", &asserter.method(:around1)
    callbacks.add_callback :around_another_event, "arg2", &asserter.method(:around2)
    callbacks.add_callback :around_another_event, "arg3", &asserter.method(:around3)

    callbacks.emit_another_event "arg" do |*args|
      asserter.yield_event(*args)
    end
  end

  def test_around_callback_without_yield
    callbacks.add_callback :around_another_event do
      # Does not yield
    end

    assert_raises TestCallbacks::MissingYield do
      callbacks.emit_another_event "arg" do
      end
    end
  end

  def test_around_callback_error
    # Don't print the error to STDOUT
    ::Exekutor.config.stubs(:quiet?).returns(true)
    error_class = Class.new(StandardError)
    callbacks.add_callback :around_another_event do
      raise error_class, "test"
    end
    ::Exekutor.expects(:on_fatal_error).with(kind_of(error_class), kind_of(String))

    asserter = mock
    asserter.expects(:yield_event).with("arg")

    callbacks.emit_another_event "arg" do |*args|
      asserter.yield_event(*args)
    end
  end

  def test_on_callback
    asserter = mock
    asserter.expects(:on).with("arg", "arg2")
    callbacks.on_event "arg2", &asserter.method(:on)
    callbacks.emit_event "arg"
  end

  def test_on_callback_error
    error_class = Class.new(StandardError)
    callbacks.on_event do
      raise error_class, "test"
    end
    ::Exekutor.expects(:on_fatal_error).with(kind_of(error_class), kind_of(String))
    callbacks.emit_event "arg"
  end
end
