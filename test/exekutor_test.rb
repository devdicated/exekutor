# frozen_string_literal: true

require "rails_helper"
require "fixtures/test_jobs"

class ExekutorTest < Minitest::Test
  def test_version_set
    refute_nil ::Exekutor::VERSION
  end

  def test_integration
    stub_logger = stub(debug: true, info: true)
    stub_logger.stubs(:tagged).returns(stub_logger)
    Exekutor.stubs(:logger).returns(stub_logger)
    worker = Exekutor::Worker.start(queues: "integration-test-queue")

    TestJobs::Simple.executed = false
    test_job = TestJobs::Simple.set(queue: "integration-test-queue").perform_later
    assert Exekutor::Job.where(active_job_id: test_job.job_id).exists?

    # LISTEN/NOTIFY trigger is not added to test DB
    worker.reserve_jobs

    wait_until { TestJobs::Simple.executed }
    assert TestJobs::Simple.executed
  ensure
    worker&.stop
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
