# frozen_string_literal: true

require_relative "../rails_helper"

class ListenerTest < Minitest::Test
  attr_reader :listener, :provider, :thread_pool, :queues

  def setup
    super
    @thread_pool = Concurrent::FixedThreadPool.new(2)
    @queues = []
    @provider = Exekutor.const_get(:Internal)::Provider.new(reserver: mock, executor: mock, pool: thread_pool,
                                                            polling_interval: nil)
    @listener = Exekutor.const_get(:Internal)::Listener.new(worker_id: "test-worker-id", queues: @queues,
                                                            provider: @provider, pool: thread_pool)
    @listener.start
  end

  def teardown
    listener.stop if listener&.running?
    super
  end

  def test_stop_with_inactive_db_connection
    ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.any_instance
                                                       .expects(:execute)
                                                       .raises(ActiveRecord::ConnectionNotEstablished)
    listener.stop
  end

  def test_provider_channel
    assert_equal "exekutor::worker::test-worker-id", listener.send(:provider_channel)
  end

  def test_restart_on_error
    error_class = Class.new(StandardError)

    Exekutor.expects(:on_fatal_error).with(instance_of(error_class), "[Listener] Runtime error!")
    listener.send(:logger).expects(:info).with(regexp_matches(/^Restarting in \d+(.\d+)? seconds…$/))
    Concurrent::ScheduledTask.expects(:execute).with(kind_of(Numeric), executor: thread_pool)

    PG::Connection.any_instance.expects(:wait_for_notify).raises(error_class)
    Exekutor::Job.connection.exec_query(%(NOTIFY "#{listener.send(:provider_channel)}"))

    wait_until_executables_started

    thread_running = listener.instance_variable_get(:@thread_running)
    wait_until { thread_running.false? }
  end

  def test_job_notification
    wait_until { listener.send(:listening?) }

    scheduled_at = 5.minutes.from_now.to_f
    provider.expects(:update_earliest_scheduled_at).with(scheduled_at)

    Exekutor::Job.connection.exec_query(
      %(NOTIFY "#{listener.class::JOB_ENQUEUED_CHANNEL}", 'id:test-id;q:test-queue;t:#{scheduled_at}';)
    )
    sleep(0.1)
  end

  def test_corrupt_payload
    wait_until { listener.send(:listening?) }

    listener.send(:logger).expects(:error).with(regexp_matches(/^Invalid notification payload: corrupt$/))

    Exekutor::Job.connection.exec_query(
      %(NOTIFY "#{listener.class::JOB_ENQUEUED_CHANNEL}", 'corrupt';)
    )
    sleep(0.1)
  end

  def test_incomplete_payload
    wait_until { listener.send(:listening?) }

    listener.send(:logger).expects(:error).with(regexp_matches(/^\[Listener\] Notification payload is missing t$/))

    Exekutor::Job.connection.exec_query(
      %(NOTIFY "#{listener.class::JOB_ENQUEUED_CHANNEL}", 'id:test-id;q:test-queue;')
    )
    sleep(0.1)
  end

  def test_queue_filter
    queues.push "my-queue"
    wait_until { listener.send(:listening?) }

    provider.expects(:update_earliest_scheduled_at).never

    Exekutor::Job.connection.exec_query(
      %(NOTIFY "#{listener.class::JOB_ENQUEUED_CHANNEL}", 'id:test-id;q:test-queue;t:#{Time.current.to_f}';)
    )
    sleep(0.1)
  end

  def test_set_connection_name
    listener.stop
    @listener = Exekutor.const_get(:Internal)::Listener.new(worker_id: "test-worker-id", set_db_connection_name: true,
                                                            provider: @provider, pool: thread_pool)
    Exekutor.const_get(:Internal)::DatabaseConnection.expects(:set_application_name)
                                                     .with(instance_of(PG::Connection), "test-worker-id", :listener)

    listener.start
    wait_until { listener.send(:listening?) }
  end

  def test_connection_verification
    not_a_pg_connection = "this is not a pg connection"
    ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.any_instance.expects(:raw_connection)
                                                       .returns(not_a_pg_connection)
    Exekutor.expects(:on_fatal_error).with(instance_of(Exekutor.const_get(:Internal)::Listener::UnsupportedDatabase),
                                           "[Listener] Runtime error!")

    wait_until_executables_started
    sleep(0.1)

    assert_equal :crashed, listener.state
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
