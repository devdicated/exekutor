# frozen_string_literal: true

require_relative "../rails_helper"

class ReserverTest < Minitest::Test
  attr_reader :reserver, :reserver_with_queues

  def setup
    super
    @reserver = Exekutor.const_get(:Internal)::Reserver.new("test-worker-id", nil)
    @reserver_with_queues = Exekutor.const_get(:Internal)::Reserver.new("test-worker-id", %i[queue1 queue2])
  end

  def test_reserve_without_availability
    Exekutor::Job.expects(:connection).never

    refute reserver.reserve(0)
  end

  def test_reserve_all_queues
    mock_connection = mock.responds_like_instance_of(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter)
    mock_connection.expects(:exec_query).with(
      all_of(
        includes("SET worker_id = $1, status = 'e'"),
        includes(%q(WHERE scheduled_at <= now() AND "status"='p')),
        includes("ORDER BY priority, scheduled_at, enqueued_at"),
        includes("FOR UPDATE SKIP LOCKED")
      ), "Exekutor::Reserve", ["test-worker-id", 1234], prepare: true
    ).returns([{ "id" => "test-id" }])

    Exekutor::Job.stubs(:connection).returns(mock_connection)
    reserver.reserve(1234)
  end

  def test_job_parser
    scheduled_at = Time.current
    jobs = reserver.send(:parse_jobs, [
      {
        "id" => "test-id-1",
        "payload" => '{"key":"value","int": 1234}',
        "options" => '{"option1":123,"option2":"value2"}',
        "scheduled_at" => scheduled_at
      },
      {
        "id" => "test-id-2",
        "payload" => '{"key":"value3","int": 2345}',
        "options" => '{"option1":456,"option2":"value22"}',
        "scheduled_at" => scheduled_at
      }
    ])

    assert jobs
    assert_equal 2, jobs.length
    assert_equal({ id: "test-id-1", payload: { "key" => "value", "int" => 1234 },
                   options: { "option1" => 123, "option2" => "value2" }, scheduled_at: scheduled_at }, jobs.first)
    assert_equal({ id: "test-id-2", payload: { "key" => "value3", "int" => 2345 },
                   options: { "option1" => 456, "option2" => "value22" }, scheduled_at: scheduled_at }, jobs.second)
  end

  def test_queue_filter_sql
    refute reserver.send(:build_queue_filter_sql, nil)
    refute reserver.send(:build_queue_filter_sql, [])
    assert_equal "AND queue = 'queue'", reserver.send(:build_queue_filter_sql, "queue")
    assert_equal "AND queue = 'queue'", reserver.send(:build_queue_filter_sql, :queue)
    assert_equal "AND queue = 'queue'", reserver.send(:build_queue_filter_sql, ["queue"])
    assert_equal "AND queue IN ('queue1','queue2')", reserver.send(:build_queue_filter_sql, %w[queue1 queue2])
    assert_equal "AND queue IN ('queue1','queue2')", reserver.send(:build_queue_filter_sql, %i[queue1 queue2])
    assert_raises(ArgumentError) { reserver.send(:build_queue_filter_sql, 1) }
    assert_raises(ArgumentError) { reserver.send(:build_queue_filter_sql, " ") }
    assert_raises(ArgumentError) { reserver.send(:build_queue_filter_sql, ["queue", 1]) }
    assert_raises(ArgumentError) { reserver.send(:build_queue_filter_sql, ["queue", :""]) }
  end

  def test_get_abandoned_jobs
    scheduled_at = Time.current

    mock_relation = mock
    mock_relation.expects(:where).with(worker_id: "test-worker-id").returns(mock_relation)
    mock_relation.expects(:where).with.returns(mock_relation)
    mock_relation.expects(:not).with(id: [1, 2, 3]).returns(mock_relation)
    mock_relation.expects(:pluck).with(:id, :payload, :options, :scheduled_at).returns(
      [
        ["test-id-1", { payload: "payload" }, { options: "options" }, scheduled_at],
        ["test-id-2", { payload: "payload2" }, { options: "options2" }, scheduled_at]
      ]
    )
    Exekutor::Job.expects(:executing).returns(mock_relation)

    jobs = reserver.get_abandoned_jobs([1, 2, 3])

    assert jobs
    assert_equal 2, jobs.length
    assert_equal({ id: "test-id-1", payload: { payload: "payload" }, options: { options: "options" },
                   scheduled_at: scheduled_at }, jobs.first)
    assert_equal({ id: "test-id-2", payload: { payload: "payload2" }, options: { options: "options2" },
                   scheduled_at: scheduled_at }, jobs.second)
  end

  def test_get_earliest_scheduled_at
    Exekutor::Job.expects(:pending).returns(mock(minimum: nil))
    reserver.earliest_scheduled_at
  end

  def test_get_earliest_scheduled_at_with_queues
    mock_relation = mock
    mock_relation.expects(:where!).with("queue IN ('queue1','queue2')").returns(mock_relation)
    mock_relation.expects(:minimum).with(:scheduled_at).returns(nil)
    Exekutor::Job.expects(:pending).returns(mock_relation)
    reserver_with_queues.earliest_scheduled_at
  end
end
