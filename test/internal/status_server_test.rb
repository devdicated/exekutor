# frozen_string_literal: true

require_relative "../rails_helper"
require "rackup/handler"
require "net/http"

class StatusServerTest < Minitest::Test
  include Rack::Test::Methods

  attr_reader :worker, :pool, :server, :port

  def random_port
    server = TCPServer.new("127.0.0.1", 0)
    server.addr[1]
    server.close
  end

  def app
    Exekutor.const_get(:Internal)::StatusServer::App.new(worker, 10.minutes)
  end

  def setup
    super
    # Don't print to STDOUT
    ::Exekutor.config.stubs(:quiet?).returns(true)

    @worker = mock.responds_like_instance_of(Exekutor::Worker)
    @worker.stubs(id: "worker-test-id", state: "worker-test-state")
    @port = random_port
    @pool = Concurrent::FixedThreadPool.new(1)
    @server = Exekutor.const_get(:Internal)::StatusServer.new(
      worker: @worker, pool: @pool, port: @port
    )
  end

  def teardown
    super
    server&.stop if server.running?
  end

  def test_running
    server.start
    # wait max 500 ms for the server to start
    wait_until { server.running? }

    assert_predicate server, :running?

    server.stop
    wait_until { !server.running? }

    refute_predicate server, :running?
  end

  def test_root
    get "/"

    assert_predicate last_response, :ok?
    assert_match %r{GET /ready}, last_response.body
    assert_match %r{GET /live}, last_response.body
  end

  def test_live_happy_flow
    worker.expects(running?: true, last_heartbeat: Time.current)

    get "/live"

    assert_predicate last_response, :ok?
  end

  def test_live_with_inactive_worker
    worker.expects(running?: false)

    get "/live"

    assert_equal 503, last_response.status
  end

  def test_live_with_flatlined_worker
    worker.expects(running?: true, last_heartbeat: 601.seconds.ago)

    get "/live"

    assert_equal 503, last_response.status
  end

  def test_live_with_inactive_connection
    worker.expects(running?: true, last_heartbeat: Time.current)
    Exekutor::Job.stubs(:connection).returns(stub(active?: false))

    get "/live"

    assert_predicate last_response, :ok?
  end

  def test_ready_happy_flow
    worker.expects(running?: true, last_heartbeat: Time.current)
    Exekutor::Job.connection_pool.expects(:with_connection).yields(mock(active?: true))

    get "/ready"

    assert_predicate last_response, :ok?
  end

  def test_ready_with_inactive_worker
    worker.expects(running?: false)

    get "/ready"

    assert_equal 503, last_response.status
  end

  def test_ready_with_flatlined_worker
    worker.expects(running?: true, last_heartbeat: 601.seconds.ago)
    Exekutor::Job.connection_pool.expects(:with_connection).yields(mock(active?: true))

    get "/ready"

    assert_equal 503, last_response.status
  end

  def test_ready_with_inactive_connection
    worker.stubs(running?: true, last_heartbeat: Time.current)
    Exekutor::Job.connection_pool.expects(:with_connection).yields(mock(active?: false))

    get "/ready"

    assert_equal 503, last_response.status
  end

  def test_threads
    worker.stubs(running?: true, thread_stats: { minimum: 1, maximum: 3, available: 3, usage_percent: 0 })
    get "/threads"

    assert_equal 200, last_response.status
  end

  def test_threads_when_not_running
    worker.stubs(running?: false)

    get "/threads"

    assert_equal 503, last_response.status
  end

  def test_invalid_path
    get "/nonexisting"

    assert_equal 404, last_response.status
  end

  def test_server_crash
    error_class = Class.new(StandardError)
    Exekutor.expects(:on_fatal_error).with(instance_of(error_class), includes("[Status server]"))
    Concurrent::ScheduledTask.expects(:execute).with(10.0, executor: pool)
    # Suppress logger output
    server.send(:logger).expects(:info)

    has_raised = false
    handler = Rackup::Handler.get("webrick")
    handler.expects(:run).with { has_raised = true }.raises(error_class)

    server.start
    # wait max 500 ms for the server to crash
    wait_until { has_raised }
  end

  def test_handler_with_stop
    handler = Class.new(TestRackHandler) do
      alias_method :stop, :_stop
    end.new
    Rackup::Handler.expects(:get).with("test").returns(handler)
    @server = Exekutor.const_get(:Internal)::StatusServer.new(
      worker: @worker, pool: @pool, port: @port, handler: "test"
    )

    server.start
    # wait max 500 ms for the server to start
    wait_until { server.running? }

    server.stop
  end

  def test_handler_without_shutdown
    handler = TestRackHandler.new
    Rackup::Handler.expects(:get).with("test").returns(handler)
    @server = Exekutor.const_get(:Internal)::StatusServer.new(
      worker: @worker, pool: @pool, port: @port, handler: "test"
    )

    server.start
    # wait max 500 ms for the server to start
    wait_until { server.running? }

    Exekutor.expects(:print_error).with(includes("Cannot shutdown status server"))
    server.stop
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

  class TestRackHandler
    attr_reader :running

    def initialize
      @running = false
    end

    def run(*, **)
      yield self
      @running = true

      sleep 0.05 while @running
    end

    def _stop
      @running = false
    end
  end
end
