# frozen_string_literal: true

require "rails_helper"
require "fixtures/test_jobs"

class WorkerTest < Minitest::Test
  attr_reader :worker

  def setup
    super
    @worker = Exekutor::Worker.start(max_threads: 2)
  end

  def teardown
    super
    worker.stop if worker.running?
    worker.record&.destroy
  end

  def test_startup_shutdown_hooks
    worker.stop
    wait_until { worker.record.destroyed? }

    hooks = ::Exekutor.const_get(:Internal)::Hooks.new
    ::Exekutor.stubs(:hooks).returns(hooks)

    worker = Exekutor::Worker.new

    mock_hook = mock
    mock_hook.expects(:before_startup).with(worker)
    mock_hook.expects(:after_startup).with(worker)
    mock_hook.expects(:before_shutdown).with(worker)
    mock_hook.expects(:after_shutdown).with(worker)

    Exekutor.hooks.before_startup { |*args| mock_hook.before_startup(*args) }
    Exekutor.hooks.after_startup { |*args| mock_hook.after_startup(*args) }

    Exekutor.hooks.before_shutdown { |*args| mock_hook.before_shutdown(*args) }
    Exekutor.hooks.after_shutdown { |*args| mock_hook.after_shutdown(*args) }

    worker.start
    wait_until { worker.record.running? }
    worker.stop
    wait_until { worker.record.destroyed? }
  ensure
    # Use kill to circumvent hooks
    worker&.kill
  end

  def test_reserve_jobs
    worker.instance_variable_get(:@provider).expects(:poll)
    worker.reserve_jobs
  end

  def test_id
    refute_nil worker.record.id
    assert_equal worker.record.id, worker.id
  end

  def test_heartbeat
    expected_timestamp = 1.minute.ago
    worker.record.expects(:last_heartbeat_at).returns(expected_timestamp)

    assert_equal expected_timestamp, worker.last_heartbeat
  end

  def test_provider_options
    assert_equal(
      { polling_interval: 123, interval_jitter: 45 },
      worker.send(:provider_options, { polling_interval: 123, polling_jitter: 45, other_option: "test" })
    )
  end

  def test_listener_options
    assert_equal(
      { queues: %w[queue1 queue2], set_db_connection_name: true },
      worker.send(:listener_options, { queues: %w[queue1 queue2], set_db_connection_name: true, other_option: "test" })
    )
  end

  def test_status_server_options
    assert_equal(
      { port: 12_345, handler: "HandlerName", heartbeat_timeout: 123 },
      worker.send(:status_server_options, { status_server_port: 12_345, status_server_handler: "HandlerName",
                                            healthcheck_timeout: 123, other_option: "test" })
    )
  end

  def test_join
    wait_until { worker.record.running? }

    join_called = false
    join_completed = false
    Thread.new do
      join_called = true
      worker.join
      join_completed = true
    end

    wait_until { join_called }

    refute join_completed
    worker.stop
    wait_until { worker.record.destroyed? }
    sleep(0.05)

    assert join_completed
  end

  def test_wait_for_termination_immediate
    worker.instance_variable_get(:@executor).expects(:wait_for_termination).never
    worker.instance_variable_get(:@executor).expects(:kill)
    worker.send(:wait_for_termination, 0)
  end

  def test_wait_for_termination_failed_wait
    timeout = rand(123..456)
    worker.instance_variable_get(:@executor).expects(:wait_for_termination).with(timeout).returns(false)
    worker.instance_variable_get(:@executor).expects(:kill)
    worker.send(:wait_for_termination, timeout)
  end

  def test_wait_for_termination_successful_wait
    timeout = rand(123..456)
    worker.instance_variable_get(:@executor).expects(:wait_for_termination).with(timeout).returns(true)
    worker.instance_variable_get(:@executor).expects(:kill).never
    worker.send(:wait_for_termination, timeout)
  end

  def test_wait_for_termination_indeterminate
    worker.instance_variable_get(:@executor).expects(:wait_for_termination).with.returns(false)
    worker.instance_variable_get(:@executor).expects(:kill).never
    worker.send(:wait_for_termination, true)
  end

  def test_status_server
    worker.stop
    wait_until { worker.record.destroyed? }

    worker = Exekutor::Worker.new(status_server_port: 12_345)

    assert(
      worker.instance_variable_get(:@executables).any?(Exekutor.const_get(:Internal)::StatusServer)
    )
  ensure
    worker&.kill
  end

  def test_thread_stats
    assert_equal(
      { minimum: 1, maximum: 2, available: 2, usage_percent: 0 },
      worker.thread_stats
    )
    worker.instance_variable_get(:@executor).stubs(:available_threads).returns(1)

    assert_equal(
      { minimum: 1, maximum: 2, available: 1, usage_percent: 50 },
      worker.thread_stats
    )
    worker.instance_variable_get(:@executor).stubs(:available_threads).returns(0)

    assert_equal(
      { minimum: 1, maximum: 2, available: 0, usage_percent: 100 },
      worker.thread_stats
    )
  end

  def test_job_execution_heartbeat
    worker.record.expects(:heartbeat!)
    worker.instance_variable_get(:@provider).expects(:poll)
    worker.instance_variable_get(:@executor).post({ id: "test-job-id", payload: TestJobs::Simple.new.serialize })
    wait_until { worker.instance_variable_get(:@executor).active_job_ids.include? "test-job-id" }
    wait_until { worker.instance_variable_get(:@executor).active_job_ids.exclude? "test-job-id" }
  end

  def test_queue_empty_heartbeat
    worker.record.expects(:heartbeat!).at_least_once
    worker.instance_variable_get(:@executor).expects(:prune_pool).at_least_once
    worker.instance_variable_get(:@reserver).expects(:reserve).at_least_once.returns(nil)
    hook_called = false
    worker.instance_variable_get(:@provider).on_queue_empty { hook_called = true }
    worker.reserve_jobs
    wait_until { hook_called }
  end

  private

  def wait_until(max_tries = 50, sleep: 0.01)
    while (tries ||= 0) < max_tries
      return true if yield

      tries += 1
      sleep(sleep)
    end
    false
  end
end
