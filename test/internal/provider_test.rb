# frozen_string_literal: true

require_relative "../rails_helper"
require "timecop"

class ProviderTest < Minitest::Test
  attr_reader :provider, :reserver, :executor, :thread_pool

  def setup
    super
    @thread_pool = Concurrent::FixedThreadPool.new(2)
    @reserver = Exekutor.const_get(:Internal)::Reserver.new("test-worker-id", queues: ["provider-test-queue-name"])
    @executor = Exekutor.const_get(:Internal)::Executor.new(max_threads: 1)
    @provider = Exekutor.const_get(:Internal)::Provider.new(reserver: reserver, executor: executor, pool: thread_pool,
                                                            polling_interval: 60)

    # Prevent firing any queries to the DB
    reserver.stubs(:reserve).returns(nil)

    @provider.start
    @executor.start
  end

  def teardown
    provider.stop if provider&.running?
    executor.stop if executor&.running?

    super
  end

  def test_poll
    reserver.unstub(:reserve)
    wait_until_executables_started

    executor.expects(:available_threads).at_least_once.returns(123)
    reserver.expects(:reserve).with(123).at_least_once

    provider.poll
    sleep(0.1)
  end

  def test_provision
    reserver.unstub(:reserve)
    wait_until_executables_started

    executor.stubs(:available_threads).at_least_once.returns(123)
    reserver.expects(:reserve).with(123).returns([{ id: "test-job-1" }, { id: "test-job-2" }, { id: "test-job-3" }])

    provider.send(:logger).expects(:debug).with("Reserved 3 job(s)")
    executor.expects(:post).with({ id: "test-job-1" })
    executor.expects(:post).with({ id: "test-job-2" })
    executor.expects(:post).with({ id: "test-job-3" })

    provider.poll
    sleep(0.1)
  end

  def test_restart_abandoned_jobs
    reserver.expects(:get_abandoned_jobs).returns([{ id: "test-job-1" }, { id: "test-job-2" }])
    provider.send(:logger).expects(:info).with("Restarting 2 abandoned jobs")
    executor.expects(:post).with({ id: "test-job-1" })
    executor.expects(:post).with({ id: "test-job-2" })

    wait_until_executables_started
    sleep(0.1)
  end

  def test_worker_overflow
    reserver.unstub(:reserve)
    wait_until_executables_started

    executor.stubs(:available_threads).returns(1)
    reserver.stubs(:reserve).with(1).returns([{ id: "test-job-1" }])
    executor.stubs(:post)
    # Silence log
    provider.send(:logger).stubs(:debug)

    next_job_timestamp = provider.instance_variable_get(:@next_job_scheduled_at)
    next_job_timestamp.expects(:set).with { |time| time < Time.now.to_f }

    provider.poll
    sleep(0.1)
  end

  def test_queue_empty_callback
    reserver.unstub(:reserve)

    mock_callback = mock
    mock_callback.expects(:on_queue_empty)

    provider.on_queue_empty do
      mock_callback.on_queue_empty
    end

    wait_until_executables_started

    executor.stubs(:available_threads).returns(123)
    reserver.expects(:reserve).with(123).returns(nil)

    provider.poll
    sleep(0.1)
  end

  def test_perform_pending_job_updates
    executor.expects(:pending_job_updates).returns([[1, { update: 123 }], [2, :destroy], [3, { other_update: "test" }]])

    Exekutor::Job.expects(:where).with(id: 1)
                 .returns(mock.tap { |m| m.expects(:update_all).with({ update: 123 }) })
    Exekutor::Job.expects(:where).with(id: 3)
                 .returns(mock.tap { |m| m.expects(:update_all).with({ other_update: "test" }) })

    Exekutor::Job.expects(:destroy).with(2)

    wait_until_executables_started
    sleep(0.1)
  end

  def test_perform_pending_job_updates_without_connection
    # Make sure the thread does not get in the way
    provider.stop

    updates = { 1 => { update: 123 }, 2 => :destroy }
    executor.stubs(:pending_job_updates).returns(updates)

    Exekutor::Job.expects(:connection).returns(mock(active?: false))
    Exekutor::Job.expects(:where).with(id: 1).raises(ActiveRecord::ConnectionNotEstablished)
    Exekutor::Job.expects(:destroy).never

    provider.send(:perform_pending_job_updates)

    assert_equal({ 1 => { update: 123 }, 2 => :destroy }, updates)
  end

  def test_update_earliest_scheduled_at_without_args
    scheduled_at = 5.minutes.from_now
    reserver.expects(:earliest_scheduled_at).returns(scheduled_at)
    provider.update_earliest_scheduled_at

    assert_equal scheduled_at.to_f, provider.send(:next_job_scheduled_at)
  end

  def test_update_earliest_scheduled_at_when_unknown
    scheduled_at = 5.minutes.from_now
    provider.update_earliest_scheduled_at(scheduled_at.to_f)

    assert_nil provider.send(:next_job_scheduled_at)
  end

  def test_update_earliest_scheduled_at_with_numeric
    # Ensure the current value is not UNKNOWN
    reserver.expects(:earliest_scheduled_at).returns(1.hour.from_now)
    provider.update_earliest_scheduled_at

    scheduled_at = 5.minutes.from_now.to_f
    provider.update_earliest_scheduled_at(scheduled_at)

    assert_equal scheduled_at, provider.send(:next_job_scheduled_at)
  end

  def test_update_earliest_scheduled_at_with_time
    # Ensure the current value is not UNKNOWN
    reserver.expects(:earliest_scheduled_at).returns(1.hour.from_now)
    provider.update_earliest_scheduled_at

    scheduled_at = 5.minutes.from_now
    provider.update_earliest_scheduled_at(scheduled_at)

    assert_equal scheduled_at.to_f, provider.send(:next_job_scheduled_at)
  end

  def test_update_earliest_scheduled_at_with_later_time
    scheduled_at = 5.minutes.from_now
    reserver.expects(:earliest_scheduled_at).returns(scheduled_at)
    provider.update_earliest_scheduled_at

    provider.update_earliest_scheduled_at(10.minutes.from_now)

    assert_equal scheduled_at.to_f, provider.send(:next_job_scheduled_at)
  end

  def test_update_earliest_scheduled_at_with_string
    assert_raises(ArgumentError) { provider.update_earliest_scheduled_at("this is not a time") }
  end

  def test_restart_on_error
    error_class = Class.new(StandardError)

    Exekutor.expects(:on_fatal_error).with(instance_of(error_class), "[Provider] Runtime error!")
    provider.send(:logger).expects(:info).with(regexp_matches(/^Restarting in \d+(.\d+)? seconds…$/))
    Concurrent::ScheduledTask.expects(:execute).with(kind_of(Numeric), executor: thread_pool)

    executor.stubs(:available_threads).returns(3)
    reserver.expects(:reserve).raises(error_class)

    wait_until_executables_started
    thread_running = provider.instance_variable_get(:@thread_running)
    wait_until { thread_running.true? }

    provider.poll

    wait_until { thread_running.false? }
    sleep(0.1)
  end

  def test_provision_error
    reserver.unstub(:reserve)

    error_class = Class.new(StandardError)
    wait_until_executables_started

    executor.stubs(:available_threads).returns(123)
    reserver.stubs(:reserve).with(123).returns([{ id: "test-job-1" }, { id: "test-job-2" }])

    provider.send(:logger).stubs(:debug)
    provider.send(:logger).stubs(:info)
    Exekutor::Job.expects(:where).with(id: %w[test-job-1 test-job-2], status: "e").returns(mock(update_all: true))
    # The error should be re-raised
    Exekutor.expects(:on_fatal_error).with(instance_of(error_class), "[Provider] Runtime error!")

    executor.expects(:post).raises(error_class)

    provider.poll
    sleep(0.1)
  end

  def test_wait_error
    error_class = Class.new(StandardError)
    Exekutor.expects(:on_fatal_error).with(instance_of(error_class), "[Provider] An error occurred while waiting")
            .at_least_once
    provider.instance_variable_get(:@event).expects(:wait).at_least_once.raises(error_class)

    wait_until_executables_started

    sleep(0.1)
  end

  def test_wait_timeout_without_poll
    # Ensure the initial update has been reset
    provider.instance_variable_get(:@next_poll_at).update { nil }
    provider.stubs(:polling_enabled?).returns(false)
    provider.stubs(:next_job_scheduled_at).returns(nil)

    assert_equal 300, provider.send(:wait_timeout)
  end

  def test_wait_timeout_with_immediate_job
    Timecop.freeze do
      # Wait should not be called if the timout is within 1 ms
      provider.stubs(:next_job_scheduled_at).returns(Time.now.to_f + 0.001)

      assert_equal 0, provider.send(:wait_timeout)
    end
  end

  def test_wait_timeout_with_job_before_poll
    Timecop.freeze do
      provider.stubs(:next_job_scheduled_at).returns(20.seconds.from_now.to_f)
      provider.stubs(:next_poll_scheduled_at).returns(200.seconds.from_now.to_f)

      assert_equal 20, provider.send(:wait_timeout)
    end
  end

  def test_wait_timeout_with_poll_before_job
    Timecop.freeze do
      provider.stubs(:next_job_scheduled_at).returns(200.seconds.from_now.to_f)
      provider.stubs(:next_poll_scheduled_at).returns(20.seconds.from_now.to_f)

      assert_equal 20, provider.send(:wait_timeout)
    end
  end

  def test_reserve_jobs_now_with_poll
    Timecop.freeze do
      provider.stubs(:next_poll_scheduled_at).returns(Time.now.to_f + 0.001)

      assert provider.send(:reserve_jobs_now?)
    end
  end

  def test_reserve_jobs_now_with_immediate_job
    Timecop.freeze do
      provider.stubs(:next_poll_scheduled_at).returns(20.seconds.from_now.to_f)
      provider.stubs(:next_job_scheduled_at).returns(Time.now.to_f)

      assert provider.send(:reserve_jobs_now?)
    end
  end

  def test_reserve_jobs_now_with_future_job
    provider.stubs(:next_poll_scheduled_at).returns(20.seconds.from_now.to_f)
    provider.stubs(:next_job_scheduled_at).returns(40.seconds.from_now.to_f)

    refute provider.send(:reserve_jobs_now?)
  end

  def test_polling_interval_with_jitter
    provider.stubs(:polling_interval_jitter).returns(6)
    interval1 = provider.send(:polling_interval)
    interval2 = provider.send(:polling_interval)
    # In the highly unlikely case that we've generated the same random twice, generate another random
    interval2 = provider.send(:polling_interval) if interval2 == interval1

    assert_in_delta 60, interval1, 3
    assert_in_delta 60, interval2, 3
    refute_equal interval1, interval2
  end

  def test_polling_interval_without_jitter
    provider.stubs(:polling_interval_jitter).returns(0)

    assert_equal 60, provider.send(:polling_interval)
    assert_equal 60, provider.send(:polling_interval)
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

  def wait_until_executables_started
    wait_until { thread_pool.queue_length.zero? }
  end
end
