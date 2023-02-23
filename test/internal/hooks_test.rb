# frozen_string_literal: true

require_relative "../test_helper"

class InternalHooksTest < Minitest::Test
  attr_reader :hooks

  def setup
    super
    @hooks = ::Exekutor.const_get(:Internal)::Hooks.new
  end

  def test_register_with_args
    callback = -> {}
    hooks.register { |hooks| hooks.before_startup(&callback) }
    assert_includes hooks.send(:__callbacks)[:before_startup], [callback, []]
  end

  def test_register_without_args
    callback = -> {}
    hooks.register { before_startup(&callback) }
    assert_includes hooks.send(:__callbacks)[:before_startup], [callback, []]
  end

  def test_register_with_hook
    instance = TestHook.new
    TestHook.expects(:new).returns(instance)
    hooks.register TestHook
    assert_includes hooks.send(:__callbacks)[:before_startup], [instance.method(:callback_method), []]
  end

  def test_append_hook
    instance = TestHook.new
    TestHook.expects(:new).returns(instance)
    hooks << TestHook
    assert_includes hooks.send(:__callbacks)[:before_startup], [instance.method(:callback_method), []]
  end

  def test_error_in_on_fatal_error
    error_class = Class.new(StandardError)

    asserter = mock
    asserter.expects(:failing_callback)
    asserter.expects(:fatal_error)

    hook_class = Class.new { include ::Exekutor::Hook }
    hook_class.add_callback :on_fatal_error do
      asserter.failing_callback
      raise error_class, "Test"
    end

    hooks.register hook_class
    hooks.on_fatal_error(&asserter.method(:fatal_error))

    ::Exekutor.expects(:hooks).returns(hooks)

    order = sequence("errors")
    ::Exekutor.expects(:print_error).with(kind_of(StandardError), "test").in_sequence(order)
    ::Exekutor.expects(:print_error).with(kind_of(error_class), includes("Callback error")).in_sequence(order)

    ::Exekutor.on_fatal_error(StandardError.new("original error"), "test")
  end

  def test_on_callbacks_method
    hooks.expects(:run_callbacks).with(:on, :callback, :one, "two", 3)

    ::Exekutor.expects(:hooks).returns(hooks)
    hooks.class.on(:callback, :one, "two", 3)
  end

  def test_with_callbacks_method
    order = sequence("callbacks")
    hooks.expects(:run_callbacks).with(:before, :callback, :one, "two", 3).in_sequence(order)
    hooks.expects(:run_callbacks).with(:around, :callback, :one, "two", 3).in_sequence(order)
    hooks.expects(:run_callbacks).with(:after, :callback, :one, "two", 3).in_sequence(order)

    ::Exekutor.expects(:hooks).returns(hooks)
    hooks.class.run(:callback, :one, "two", 3)
  end

  class TestHook
    include ::Exekutor::Hook

    before_startup :callback_method

    def callback_method; end
  end
end
