# frozen_string_literal: true

require "test_helper"

# noinspection RubyInstanceMethodNamingConvention
class AsynchronousTest < Minitest::Test
  attr_reader :instance

  def setup
    super
    @instance = TestClass.new
  end

  def test_instance_method_without_args
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with { |job| enqueued_job = job }
    instance.method_without_args

    refute_nil enqueued_job
    assert_equal [instance, :method_without_args, [[], nil]], enqueued_job.arguments

    instance.expects(:__immediately_method_without_args).with
    enqueued_job.perform_now
  end

  def test_instance_method_with_custom_alias
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with { |job| enqueued_job = job }
    instance.method_with_custom_alias

    refute_nil enqueued_job
    assert_equal [instance, :method_with_custom_alias, [[], nil]], enqueued_job.arguments
  end

  def test_method_without_args
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with { |job| enqueued_job = job }
    TestClass.method_without_args

    refute_nil enqueued_job
    assert_equal [TestClass, :method_without_args, [[], nil]], enqueued_job.arguments

    TestClass.expects(:__immediately_method_without_args).with
    enqueued_job.perform_now
  end

  def test_method_with_args
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with { |job| enqueued_job = job }
    TestClass.method_with_args 1, :two

    refute_nil enqueued_job
    assert_equal [TestClass, :method_with_args, [[1, :two], nil]], enqueued_job.arguments

    TestClass.expects(:__immediately_method_with_args).with(1, :two)
    enqueued_job.perform_now
  end

  def test_method_with_rest_args
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with { |job| enqueued_job = job }
    TestClass.method_with_rest 1, 2, 3, 4, 5, 6

    refute_nil enqueued_job
    assert_equal [TestClass, :method_with_rest, [[1, 2, 3, 4, 5, 6], nil]], enqueued_job.arguments

    TestClass.expects(:__immediately_method_with_rest).with(1, 2, 3, 4, 5, 6)
    enqueued_job.perform_now
  end

  def test_method_with_keyword_rest_args
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with { |job| enqueued_job = job }
    TestClass.method_with_rest 1, arg2: 2, arg3: 3

    refute_nil enqueued_job
    assert_equal [TestClass, :method_with_rest, [[1], { arg2: 2, arg3: 3 }]], enqueued_job.arguments

    TestClass.expects(:__immediately_method_with_rest).with(1, { arg2: 2, arg3: 3 })
    enqueued_job.perform_now
  end

  def test_method_with_kwargs
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with { |job| enqueued_job = job }
    TestClass.method_with_kwargs kwarg1: 1, kwarg2: :two

    refute_nil enqueued_job
    assert_equal [TestClass, :method_with_kwargs, [[], { kwarg1: 1, kwarg2: :two }]],
                 enqueued_job.arguments

    TestClass.expects(:__immediately_method_with_kwargs).with(kwarg1: 1, kwarg2: :two)
    enqueued_job.perform_now
  end

  def test_method_with_keyrest_args
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with { |job| enqueued_job = job }
    TestClass.method_with_keyrest arg1: 1, arg2: 2, arg3: 3, arg4: 4, arg5: 5

    refute_nil enqueued_job
    assert_equal [TestClass, :method_with_keyrest, [[], { arg1: 1, arg2: 2, arg3: 3, arg4: 4, arg5: 5 }]],
                 enqueued_job.arguments

    TestClass.expects(:__immediately_method_with_keyrest).with(arg1: 1, arg2: 2, arg3: 3, arg4: 4, arg5: 5)
    enqueued_job.perform_now
  end

  def test_method_with_mixed_args_minimum
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with { |job| enqueued_job = job }
    TestClass.method_with_mixed_args 1, arg3: 3

    refute_nil enqueued_job
    assert_equal [TestClass, :method_with_mixed_args, [[1], { arg3: 3 }]], enqueued_job.arguments

    TestClass.expects(:__immediately_method_with_mixed_args).with(1, arg3: 3)
    enqueued_job.perform_now
  end

  def test_method_with_mixed_args_full
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with { |job| enqueued_job = job }
    TestClass.method_with_mixed_args 1, 2, 2.5, arg3: 3, arg4: 4, arg5: 5

    refute_nil enqueued_job
    assert_equal [TestClass, :method_with_mixed_args, [[1, 2, 2.5], { arg3: 3, arg4: 4, arg5: 5 }]],
                 enqueued_job.arguments

    TestClass.expects(:__immediately_method_with_mixed_args).with(1, 2, 2.5, arg3: 3, arg4: 4, arg5: 5)
    enqueued_job.perform_now
  end

  def test_protected_method_visibility
    assert_includes instance.protected_methods, :protected_method
  end

  def test_private_method_visibility
    assert_includes instance.private_methods, :private_method
  end

  def test_private_class_method_visibility
    assert_includes TestClass.private_methods, :private_method
  end

  def test_missing_args
    assert_raises(ArgumentError) { TestClass.method_with_args }
    assert_raises(ArgumentError) { TestClass.method_with_kwargs }
    assert_raises(ArgumentError) { TestClass.method_with_rest }
    assert_raises(ArgumentError) { TestClass.method_with_keyrest }
    assert_raises(ArgumentError) { TestClass.method_with_mixed_args }
  end

  def test_extra_args
    assert_raises(ArgumentError) { instance.method_without_args :arg }
    assert_raises(ArgumentError) { TestClass.method_without_args :arg }
    assert_raises(ArgumentError) { TestClass.method_with_args 1, 2, 3, 4, 5, 6, 7, 8, 9 }
  end

  def test_missing_kwargs
    assert_raises(ArgumentError, includes("kwarg1, kwarg2")) { TestClass.method_with_kwargs }
  end

  def test_unknown_kwargs
    assert_raises(ArgumentError, includes("unknown")) do
      TestClass.method_with_kwargs kwarg1: 1, kwarg2: 2, unknown: true
    end
  end

  def test_nonexistent_method
    assert_raises(ArgumentError) { TestClass.send :perform_asynchronously, :nonexistent_method }
  end

  def test_double_call_to_asyncronous
    assert_raises(Exekutor::Asynchronous::Error) { TestClass.send :perform_asynchronously, :method_without_args }
  end

  def test_method_with_block
    assert_raises(ArgumentError) { instance.method_without_args { "testing " } }
  end

  def test_job_for_missing_delegate
    assert_raises(Exekutor::Asynchronous::Error) do
      Exekutor::Asynchronous::AsyncMethodJob.perform_now nil, :method, []
    end
  end

  def test_job_for_invalid_delegate
    assert_raises(Exekutor::Asynchronous::Error) do
      Exekutor::Asynchronous::AsyncMethodJob.perform_now Object, :method, []
    end
  end

  def test_job_for_invalid_method
    assert_raises(Exekutor::Asynchronous::Error) do
      Exekutor::Asynchronous::AsyncMethodJob.perform_now TestClass, :invalid_method, []
    end
  end

  def test_job_for_non_async_method
    assert_raises(Exekutor::Asynchronous::Error) do
      Exekutor::Asynchronous::AsyncMethodJob.perform_now TestClass, :not_an_async_method, []
    end
  end

  class TestClass
    include ::Exekutor::Asynchronous

    def method_without_args; end

    perform_asynchronously :method_without_args

    def method_with_custom_alias; end

    perform_asynchronously :method_with_custom_alias, alias_to: :alias_to_method_with_custom_alias

    protected

    def protected_method; end

    perform_asynchronously :protected_method

    private

    def private_method; end

    perform_asynchronously :private_method

    class << self
      def method_without_args; end

      def method_with_args(arg1, arg2, arg3 = 3) end

      def method_with_kwargs(kwarg1:, kwarg2:, kwarg3: 3) end

      def method_with_rest(arg1, *rest) end

      def method_with_keyrest(arg1:, **keyrest) end

      def method_with_mixed_args(arg1, arg2 = nil, *rest, arg3:, arg4: 4, **keyrest) end # rubocop:disable Metrics/ParameterLists

      def not_an_async_method; end

      private

      def private_method; end
    end

    perform_asynchronously :method_without_args, class_method: true
    perform_asynchronously :method_with_args, class_method: true
    perform_asynchronously :method_with_kwargs, class_method: true
    perform_asynchronously :method_with_rest, class_method: true
    perform_asynchronously :method_with_keyrest, class_method: true
    perform_asynchronously :method_with_mixed_args, class_method: true
    perform_asynchronously :private_method, class_method: true
  end
end
