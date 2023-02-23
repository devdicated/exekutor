# frozen_string_literal: true

class TestHook
  include ::Exekutor::Hook
  before_startup { "before_startup_proc" }
  before_startup { |_worker| "before_startup_arg_proc" }
  add_callback :before_startup, :method_callback
  before_shutdown :method_callback
  after_shutdown :method_callback
  after_startup :method_callback
  before_enqueue :method_callback
  around_enqueue :around_callback
  after_enqueue :method_callback
  before_job_execution :method_callback
  around_job_execution :around_callback
  after_job_execution :method_callback
  on_job_failure :method_callback
  on_fatal_error :arg_callback

  def method_callback; end

  def arg_callback(_) end

  def around_callback
    yield
  end
end

class HookTest < Minitest::Test
  def test_callbacks
    hook = TestHook.new
    callbacks = hook.callbacks
    callbacks[:before_startup].map! do |cb|
      # Convert proc instances to a Proc class so we can assert equality
      if cb.is_a? Proc
        Proc
      else
        cb
      end
    end

    assert_equal({
                   before_startup: [Proc, Proc, hook.method(:method_callback)],
                   after_startup: [hook.method(:method_callback)],
                   before_shutdown: [hook.method(:method_callback)],
                   after_shutdown: [hook.method(:method_callback)],
                   before_enqueue: [hook.method(:method_callback)],
                   around_enqueue: [hook.method(:around_callback)],
                   after_enqueue: [hook.method(:method_callback)],
                   before_job_execution: [hook.method(:method_callback)],
                   around_job_execution: [hook.method(:around_callback)],
                   after_job_execution: [hook.method(:method_callback)],
                   on_job_failure: [hook.method(:method_callback)],
                   on_fatal_error: [hook.method(:arg_callback)]
                 }, callbacks)
  end

  def test_add_invalid_callback_name
    hook_class = Class.new { include ::Exekutor::Hook }
    assert_raises(::Exekutor::Error) { hook_class.add_callback :invalid, -> {} }
  end

  def test_callback_leaks
    hook_class = Class.new { include ::Exekutor::Hook }
    hook_class.add_callback :before_startup, -> {}

    hook_class2 = Class.new { include ::Exekutor::Hook }
    assert_empty hook_class2.new.callbacks
  end
end
