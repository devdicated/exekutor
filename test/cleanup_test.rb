# frozen_string_literal: true

require "test_helper"

class CleanupTest < Minitest::Test
  attr_reader :cleaner

  def setup
    super
    @cleaner = Exekutor::Cleanup.new
  end

  def test_worker_cleaning_without_args
    Timecop.freeze do
      Exekutor::Info::Worker.expects(:where).with('"last_heartbeat_at"<?', 4.hours.ago).returns(mock(destroy_all: true))
      cleaner.cleanup_workers
    end
  end

  def test_worker_cleaning_with_duration_arg
    Timecop.freeze do
      Exekutor::Info::Worker.expects(:where).with('"last_heartbeat_at"<?', 1.day.ago).returns(mock(destroy_all: true))
      cleaner.cleanup_workers timeout: 1.day
    end
  end

  def test_worker_cleaning_with_int_arg
    Timecop.freeze do
      Exekutor::Info::Worker.expects(:where).with('"last_heartbeat_at"<?', 12.hours.ago).returns(mock(destroy_all: true))
      cleaner.cleanup_workers timeout: 12
    end
  end

  def test_worker_cleaning_with_time_arg
    cleanup_time = 6.hours.ago
    Exekutor::Info::Worker.expects(:where).with('"last_heartbeat_at"<?', cleanup_time).returns(mock(destroy_all: true))
    cleaner.cleanup_workers timeout: cleanup_time
  end

  def test_job_cleaning_without_args
    mock_jobs = mock.responds_like(Exekutor::Job.all)
    Exekutor::Job.expects(:all).returns(mock_jobs)

    Timecop.freeze do
      mock_jobs.expects(:where!).with('"scheduled_at"<?', 2.days.ago)
      mock_jobs.expects(:where).returns(mock(not: mock(delete_all: true)))
      cleaner.cleanup_jobs
    end
  end

  def test_job_cleaning_with_duration_arg
    mock_jobs = mock.responds_like(Exekutor::Job.all)
    Exekutor::Job.expects(:all).returns(mock_jobs)

    Timecop.freeze do
      mock_jobs.expects(:where!).with('"scheduled_at"<?', 5.days.ago)
      mock_jobs.expects(:where).returns(mock(not: mock(delete_all: true)))
      cleaner.cleanup_jobs before: 5.days
    end
  end

  def test_job_cleaning_with_int_arg
    mock_jobs = mock.responds_like(Exekutor::Job.all)
    Exekutor::Job.expects(:all).returns(mock_jobs)

    Timecop.freeze do
      mock_jobs.expects(:where!).with('"scheduled_at"<?', 5.days.ago)
      mock_jobs.expects(:where).returns(mock(not: mock(delete_all: true)))
      cleaner.cleanup_jobs before: 120
    end
  end

  def test_job_cleaning_with_time_arg
    mock_jobs = mock.responds_like(Exekutor::Job.all)
    Exekutor::Job.expects(:all).returns(mock_jobs)

    before_time = 10.days.ago
    mock_jobs.expects(:where!).with('"scheduled_at"<?', before_time)
    mock_jobs.expects(:where).returns(mock(not: mock(delete_all: true)))
    cleaner.cleanup_jobs before: before_time
  end

  def test_job_cleaning_with_status_arg
    mock_jobs = mock.responds_like(Exekutor::Job.all)
    Exekutor::Job.expects(:all).returns(mock_jobs)
    before_time = 10.days.ago

    mock_jobs.expects(:where!).with('"scheduled_at"<?', before_time)
    mock_jobs.expects(:where!).with(status: [:f, :d])
    mock_jobs.expects(:delete_all)
    cleaner.cleanup_jobs before: before_time, status: [:f, :d]
  end

  def test_invalid_worker_timeout
    assert_raises(ArgumentError) { cleaner.cleanup_workers timeout: "not a timeout" }
  end

  def test_invalid_job_timeout
    assert_raises(ArgumentError) { cleaner.cleanup_jobs before: "not a timeout" }
  end

  def test_invalid_job_status
    assert_raises(ArgumentError) { cleaner.cleanup_jobs status: 1 }
  end
end
