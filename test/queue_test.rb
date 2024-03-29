# frozen_string_literal: true

require "rails_helper"
require "timecop"
require_relative "fixtures/test_jobs"

class QueueTest < Minitest::Test
  attr_reader :queue

  def setup
    super
    @queue = ::Exekutor::Queue.new
  end

  def test_queue_job
    job = TestJobs::Simple.new
    queue.push(job)

    assert ::Exekutor::Job.exists?(active_job_id: job.job_id)
  end

  def test_queue_jobs
    jobs = [TestJobs::Simple.new, TestJobs::Simple.new]
    queue.push(jobs)

    jobs.each do |job|
      assert ::Exekutor::Job.exists?(active_job_id: job.job_id)
    end
  end

  def test_queue_job_at
    schedule_at = 1.hour.from_now.round(6)
    job = TestJobs::Simple.new
    queue.schedule_at(job, schedule_at)

    assert ::Exekutor::Job.exists?(active_job_id: job.job_id)
    assert_equal [schedule_at], ::Exekutor::Job.where(active_job_id: job.job_id).pluck(:scheduled_at)
  end

  def test_queue_jobs_at
    schedule_at = 1.hour.from_now.round(6)
    jobs = [TestJobs::Simple.new, TestJobs::Simple.new]
    queue.schedule_at(jobs, schedule_at)
    jobs.each do |job|
      assert ::Exekutor::Job.exists?(active_job_id: job.job_id)
      assert_equal [schedule_at], ::Exekutor::Job.where(active_job_id: job.job_id).pluck(:scheduled_at)
    end
  end

  def test_invalid_queue_argument
    assert_raises(ArgumentError) { queue.push("Not an active job") }
    assert_raises(ArgumentError) { queue.schedule_at(TestJobs::Simple.new, "Not a timestamp") }
  end

  def test_custom_queue_name
    job = TestJobs::Simple.new
    job.queue_name = "test_queue_name"
    queue.push(job)

    assert_equal ["test_queue_name"], ::Exekutor::Job.where(active_job_id: job.job_id).pluck(:queue)
  end

  def test_custom_priority
    valid_priority = rand(Exekutor::Queue::VALID_PRIORITIES)
    job = TestJobs::Simple.new
    job.priority = valid_priority
    queue.push(job)

    assert_equal [valid_priority], ::Exekutor::Job.where(active_job_id: job.job_id).pluck(:priority)
  end

  def test_custom_queue_timeout
    job = TestJobs::WithOptions.new
    Timecop.freeze do
      job.enqueue(queue_timeout: 1.hour)

      assert_equal [{ "start_execution_before" => 1.hour.from_now.to_f }],
                   ::Exekutor::Job.where(active_job_id: job.job_id).pluck(:options)
    end
  end

  def test_custom_execution_timeout
    job = TestJobs::WithOptions.new
    Timecop.freeze do
      job.enqueue(execution_timeout: 1.hour)

      assert_equal [{ "execution_timeout" => 3600.0 }],
                   ::Exekutor::Job.where(active_job_id: job.job_id).pluck(:options)
    end
  end

  def test_scheduled_at_variants
    schedule_at = 1.hour.from_now.round(6)

    job = TestJobs::Simple.new
    queue.schedule_at(job, schedule_at.to_i)

    assert_equal [schedule_at.change(nsec: 0)], ::Exekutor::Job.where(active_job_id: job.job_id).pluck(:scheduled_at)

    job = TestJobs::Simple.new
    queue.schedule_at(job, schedule_at.to_f)

    assert_equal [schedule_at], ::Exekutor::Job.where(active_job_id: job.job_id).pluck(:scheduled_at)

    job = TestJobs::Simple.new
    queue.schedule_at(job, schedule_at.to_date)

    assert_equal [schedule_at.at_beginning_of_day],
                 ::Exekutor::Job.where(active_job_id: job.job_id).pluck(:scheduled_at)
  end

  def test_push_with_invalid_queue
    job = TestJobs::Simple.new
    job.queue_name = " "
    assert_raises(Exekutor::Queue::Error) { queue.push job }

    job.queue_name = "q" * 64
    assert_raises(Exekutor::Queue::Error) { queue.push job }
  end

  def test_push_with_invalid_priority
    job = TestJobs::Simple.new
    job.priority = 0
    assert_raises(Exekutor::Queue::Error) { queue.push job }

    job.priority = 32_768
    assert_raises(Exekutor::Queue::Error) { queue.push job }

    job.priority = "1234"
    assert_raises(Exekutor::Queue::Error) { queue.push job }
  end
end
