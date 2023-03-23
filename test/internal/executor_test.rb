# frozen_string_literal: true

require_relative "../rails_helper"
require_relative "../fixtures/test_jobs"
require "timecop"

class ExecutorTest < Minitest::Test
  attr_reader :executor

  def setup
    super
    @executor = Exekutor.const_get(:Internal)::Executor.new(max_threads: 1)
    @executor.start
  end

  def teardown
    executor.stop if executor&.running?
    super
  end

  def test_kill
    executor.kill
    sleep(0.01)

    assert_equal :killed, executor.state
  end

  def test_release_jobs_on_kill
    TestJobs::Blocking.block = true
    executor.post({ id: "test-job-1", payload: TestJobs::Blocking.new.serialize, options: {},
                    scheduled_at: Time.current })
    executor.post({ id: "test-job-2", payload: TestJobs::Blocking.new.serialize, options: {},
                    scheduled_at: Time.current })
    wait_until_workers_started

    executor.expects(:update_job).with({ id: "test-job-1" }, status: "p", worker_id: nil)
    executor.expects(:update_job).with({ id: "test-job-2" }, status: "p", worker_id: nil)
    executor.kill
  end

  def test_job_execution
    payload = Object.new
    job = { id: "test-job-id", payload: payload, options: {}, scheduled_at: Time.current }
    ActiveJob::Base.expects(:execute).with(payload)
    executor.expects(:update_job).with(job, has_entries(status: "c", runtime: kind_of(Numeric)))
    executor.post job
    wait_until_workers_finished
  ensure
    ActiveJob::Base.unstub(:execute)
  end

  def test_job_execution_hooks
    job = { id: "test-job-id", payload: TestJobs::Simple.new.serialize, options: {}, scheduled_at: Time.current }

    callback_sequence = sequence("callback")
    mock_callback = mock
    mock_callback.expects(:before_execution).with(job).in_sequence(callback_sequence)
    mock_callback.expects(:around_execution).with(job).in_sequence(callback_sequence).yields
    mock_callback.expects(:after_execution).with(job).in_sequence(callback_sequence)

    temp_hooks = Exekutor.const_get(:Internal)::Hooks.new
    Exekutor.stubs(:hooks).returns(temp_hooks)
    Exekutor.hooks.register do
      before_job_execution(&mock_callback.method(:before_execution))
      around_job_execution(&mock_callback.method(:around_execution))
      after_job_execution(&mock_callback.method(:after_execution))
    end

    executor.post job
    wait_until_workers_finished
  end

  def test_after_execute_callback
    mock_callback = mock
    mock_callback.expects(:after_execute)
    executor.after_execute { mock_callback.after_execute }

    job = { id: "test-job-id", payload: TestJobs::Simple.new.serialize, options: {}, scheduled_at: Time.current }
    executor.post job
    wait_until_workers_finished
  end

  def test_delete_completed_jobs
    executor&.stop
    @executor = Exekutor.const_get(:Internal)::Executor.new(max_threads: 3,
                                                            delete_completed_jobs: true,
                                                            delete_discarded_jobs: false,
                                                            delete_failed_jobs: false)
    @executor.start
    executor.stubs(:log_error)

    assert_job_deletion TestJobs::Simple.new, true
    assert_job_deletion TestJobs::Raises.new(Exekutor::DiscardJob, "test discarded job deletion"), false
    assert_job_deletion TestJobs::Raises.new(StandardError, "test failed job deletion"), false
    wait_until_workers_finished
  end

  def test_delete_discarded_jobs
    executor&.stop
    @executor = Exekutor.const_get(:Internal)::Executor.new(max_threads: 3,
                                                            delete_completed_jobs: false,
                                                            delete_discarded_jobs: true,
                                                            delete_failed_jobs: false)
    @executor.start
    executor.stubs(:log_error)

    assert_job_deletion TestJobs::Simple.new, false
    assert_job_deletion TestJobs::Raises.new(Exekutor::DiscardJob, "test discarded job deletion"), true
    assert_job_deletion TestJobs::Raises.new(StandardError, "test failed job deletion"), false
    wait_until_workers_finished
  end

  def test_delete_failed_jobs
    executor&.stop
    @executor = Exekutor.const_get(:Internal)::Executor.new(max_threads: 3,
                                                            delete_completed_jobs: false,
                                                            delete_discarded_jobs: false,
                                                            delete_failed_jobs: true)
    @executor.start
    executor.stubs(:log_error)

    assert_job_deletion TestJobs::Simple.new, false
    assert_job_deletion TestJobs::Raises.new(Exekutor::DiscardJob, "test discarded job deletion"), false
    assert_job_deletion TestJobs::Raises.new(StandardError, "test failed job deletion"), true
    wait_until_workers_finished
  end

  def test_active_job_ids
    assert_equal [], executor.active_job_ids

    TestJobs::Blocking.block = true
    job = { id: "test-job-1234", payload: TestJobs::Blocking.new.serialize, options: {}, scheduled_at: Time.current }
    executor.post job
    wait_until_workers_started
    # Wait a smidge for the worker to add the job id to the active_job_ids
    sleep 0.01

    assert_equal ["test-job-1234"], executor.active_job_ids

    TestJobs::Blocking.block = false
    wait_until_workers_finished

    assert_equal [], executor.active_job_ids
  ensure
    TestJobs::Blocking.block = false
  end

  def test_post_with_full_queue
    # Fills up worker
    TestJobs::Blocking.block = true
    job = { id: "test-job-1", payload: TestJobs::Blocking.new.serialize, options: {}, scheduled_at: Time.current }
    executor.post job
    wait_until_workers_started

    # Fills up queue
    job = { id: "test-job-2", payload: TestJobs::Simple.new.serialize, options: {}, scheduled_at: Time.current }
    executor.post job

    # Overflows queue
    job = { id: "test-job-3", payload: TestJobs::Simple.new.serialize, options: {}, scheduled_at: Time.current }
    Exekutor::Job.expects(:where).with(id: "test-job-3").returns(mock(update_all: true))
    Exekutor.logger.expects(:error)
    executor.post job
  ensure
    TestJobs::Blocking.block = false
  end

  def test_minimum_maximum_workers
    executor.stop
    @executor = Exekutor.const_get(:Internal)::Executor.new(min_threads: 123, max_threads: 234)

    assert_equal 123, executor.minimum_threads
    assert_equal 234, executor.maximum_threads
  end

  def test_available_threads
    assert_equal 1, executor.available_threads

    # Fills up worker
    TestJobs::Blocking.block = true
    job = { id: "test-job-1", payload: TestJobs::Blocking.new.serialize, options: {}, scheduled_at: Time.current }
    executor.post job
    wait_until_workers_started

    assert_equal 0, executor.available_threads

    TestJobs::Blocking.block = false
    wait_until_workers_finished

    assert_equal 1, executor.available_threads

    executor.stop

    assert_equal 0, executor.available_threads
  ensure
    TestJobs::Blocking.block = false
  end

  def test_available_jruby_workers
    Concurrent.stubs(on_jruby?: true)

    mock_executor = mock(getMaximumPoolSize: 7, getActiveCount: 3)

    executor = Exekutor.const_get(:Internal)::Executor::ThreadPoolExecutor.new
    executor.instance_variable_set(:@executor, mock_executor)

    assert_equal 4, executor.available_threads
  end

  def test_prune_pool
    executor&.stop
    @executor = Exekutor.const_get(:Internal)::Executor.new(min_threads: 1, max_threads: 3, max_thread_idletime: 60)
    @executor.start

    # Fill up queue
    TestJobs::Blocking.block = true
    3.times do |n|
      job = { id: "test-job-#{n}", payload: TestJobs::Blocking.new.serialize, options: {}, scheduled_at: Time.current }
      executor.post job
    end
    wait_until_workers_started

    assert_equal 3, executor.instance_variable_get(:@executor).length

    # Release workers
    TestJobs::Blocking.block = false
    wait_until_workers_finished

    # Cannot use Timecop here
    Concurrent.expects(:monotonic_time).at_least_once.returns(2.minutes.from_now.to_i)
    executor.prune_pool
    # wait for workers to exit
    sleep 0.1

    assert_equal 1, executor.instance_variable_get(:@executor).length
  ensure
    TestJobs::Blocking.block = false
  end

  def test_delete_job
    job = { id: "test-job-to-destroy", payload: TestJobs::Simple.new.serialize, options: {},
            scheduled_at: Time.current }
    Exekutor::Job.expects(:destroy).with("test-job-to-destroy")

    assert executor.send(:delete_job, job)
  end

  def test_delete_job_without_connection
    Exekutor::Job.connection.stubs(:active?).returns(false)
    job = { id: "test-job-to-destroy", payload: TestJobs::Simple.new.serialize, options: {},
            scheduled_at: Time.current }
    Exekutor::Job.expects(:destroy).with("test-job-to-destroy").raises(ActiveRecord::ConnectionNotEstablished)
    Exekutor.logger.expects(:error).at_least_once

    refute executor.send(:delete_job, job)
    assert_includes executor.pending_job_updates, "test-job-to-destroy"
    assert_equal :destroy, executor.pending_job_updates["test-job-to-destroy"]
  end

  def test_update_job
    job = { id: "test-job-to-update", payload: TestJobs::Simple.new.serialize, options: {}, scheduled_at: Time.current }
    Exekutor::Job.expects(:where).with(id: "test-job-to-update").returns(mock(update_all: true))

    assert executor.send(:update_job, job, status: "p", worker_id: nil)
  end

  def test_update_job_without_connection
    Exekutor::Job.connection.stubs(:active?).returns(false)
    job = { id: "test-job-to-update", payload: TestJobs::Simple.new.serialize, options: {}, scheduled_at: Time.current }
    Exekutor::Job.expects(:where).with(id: "test-job-to-update").raises(ActiveRecord::ConnectionNotEstablished)
    Exekutor.logger.expects(:error).at_least_once

    refute executor.send(:update_job, job, status: "p", worker_id: nil)
    assert_includes executor.pending_job_updates, "test-job-to-update"
    assert_equal({ status: "p", worker_id: nil }, executor.pending_job_updates["test-job-to-update"])
  end

  def test_multiple_updates_job_without_connection
    Exekutor::Job.connection.stubs(:active?).returns(false)
    executor.pending_job_updates["test-job-to-update"] = { test: "testing" }
    job = { id: "test-job-to-update", payload: TestJobs::Simple.new.serialize, options: {}, scheduled_at: Time.current }
    Exekutor::Job.expects(:where).with(id: "test-job-to-update").raises(ActiveRecord::ConnectionNotEstablished)
    Exekutor.logger.expects(:error).at_least_once

    refute executor.send(:update_job, job, status: "p", worker_id: nil)
    assert_includes executor.pending_job_updates, "test-job-to-update"
    assert_equal({ test: "testing", status: "p", worker_id: nil },
                 executor.pending_job_updates["test-job-to-update"])
  end

  def test_update_destroyed_job_without_connection
    Exekutor::Job.connection.stubs(:active?).returns(false)
    executor.pending_job_updates["test-job-to-update"] = :destroy
    job = { id: "test-job-to-update", payload: TestJobs::Simple.new.serialize, options: {}, scheduled_at: Time.current }
    Exekutor::Job.expects(:where).with(id: "test-job-to-update").raises(ActiveRecord::ConnectionNotEstablished)
    Exekutor.logger.expects(:error).at_least_once

    refute executor.send(:update_job, job, status: "p", worker_id: nil)
    assert_includes executor.pending_job_updates, "test-job-to-update"
    assert_equal(:destroy, executor.pending_job_updates["test-job-to-update"])
  end

  def test_default_max_threads
    Exekutor::Job.expects(:connection_db_config).returns(mock(pool: 5))

    assert_equal 4, executor.send(:default_max_threads)
    Exekutor::Job.unstub(:connection_db_config)

    Exekutor::Job.expects(:connection_db_config).returns(mock(pool: 1))

    assert_equal 1, executor.send(:default_max_threads)
    Exekutor::Job.unstub(:connection_db_config)
  end

  def test_execution_timeout
    TestJobs::Blocking.block = true
    job = { id: "test-job-1", payload: TestJobs::Blocking.new.serialize, options: { "execution_timeout" => 0.025 },
            scheduled_at: Time.current }
    executor.expects(:on_job_failed).with(job,
                                          instance_of(Exekutor.const_get(:Internal)::Executor::JobExecutionTimeout),
                                          anything)
    executor.post job
    wait_until_workers_finished
  ensure
    TestJobs::Blocking.block = false
  end

  def test_queue_timeout
    job = { id: "test-job-1", payload: TestJobs::Simple.new.serialize,
            options: { "start_execution_before" => Time.current.to_f }, scheduled_at: 5.minutes.ago }
    executor.expects(:on_job_failed).with(job, instance_of(Exekutor::DiscardJob), anything)
    executor.post job
    wait_until_workers_finished
  end

  def test_job_discard
    job = { id: "test-job-to-discard",
            payload: TestJobs::Raises.new(Exekutor::DiscardJob, "test discarding job").serialize,
            options: {}, scheduled_at: Time.current }
    # Discarded jobs should not cause a job failure hook
    Exekutor.const_get(:Internal)::Hooks.expects(:on).with(:job_failure, job, instance_of(Exekutor::DiscardJob)).never

    executor.expects(:update_job).with(job, has_entries(status: "d", runtime: kind_of(Numeric))).returns(true)
    Exekutor::JobError.expects(:create!)
                      .with(has_entries(job_id: "test-job-to-discard", error: instance_of(Exekutor::DiscardJob)))

    executor.post job
    wait_until_workers_finished
  end

  def test_job_failure
    job = { id: "test-job-that-failed",
            payload: TestJobs::Raises.new("test failing job").serialize,
            options: {}, scheduled_at: Time.current }

    Exekutor.const_get(:Internal)::Hooks.expects(:on).with(:job_failure, job, kind_of(StandardError))
    executor.expects(:log_error).with(kind_of(StandardError), "Job failed")
    executor.expects(:update_job).with(job, has_entries(status: "f", runtime: kind_of(Numeric))).returns(true)
    Exekutor::JobError.expects(:create!)
                      .with(has_entries(job_id: "test-job-that-failed", error: kind_of(StandardError)))

    executor.post job
    wait_until_workers_finished
  end

  def test_lost_db_connection
    ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.any_instance.stubs(active?: false)

    job = { id: "test-job-with-db-connection-drop",
            payload: TestJobs::Raises.new(ActiveRecord::StatementInvalid, "test db connection drop").serialize,
            options: {}, scheduled_at: Time.current }

    Exekutor.const_get(:Internal)::Hooks.expects(:on)
                                        .with(:job_failure, job, instance_of(ActiveRecord::StatementInvalid))
    executor.expects(:log_error).with(instance_of(ActiveRecord::StatementInvalid), "Job failed")
    executor.expects(:update_job).with(job, status: "p", worker_id: nil).returns(true)
    Exekutor::JobError.expects(:create!).never

    executor.post job
    wait_until_workers_finished
  end

  def test_execution_exception
    job = { id: "test-job-with-exception", payload: TestJobs::Raises.new(Exception, "test exception").serialize,
            options: {}, scheduled_at: Time.current }

    executor.expects(:update_job).with(job, status: "p", worker_id: nil)
    Exekutor::JobError.expects(:create!).never
    Concurrent.stubs(:global_logger).returns(mock(call: true))
    executor.post job
    wait_until_workers_finished
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

  def wait_until_workers_started
    wait_until { executor_thread_pool.queue_length.zero? }
  end

  def wait_until_workers_finished
    wait_until do
      thread_pool = executor_thread_pool
      thread_pool.queue_length.zero? && executor.available_threads == thread_pool.max_length
    end
  end

  def executor_thread_pool
    executor.instance_variable_get(:@executor)
  end

  def assert_job_deletion(job, should_delete)
    @deletion_job_number ||= 0
    job = { id: "test-job-#{@deletion_job_number += 1}", payload: job.serialize,
            options: {}, scheduled_at: Time.current }
    if should_delete
      executor.expects(:delete_job).with(job)
    else
      executor.expects(:delete_job).with(job).never
    end
    executor.post job
  end
end
