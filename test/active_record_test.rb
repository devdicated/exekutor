# frozen_string_literal: true

require "rails_helper"

class ActiveRecordTest < Minitest::Test

  def test_worker
    Exekutor::Info::Worker.create!(hostname: 'test', pid: 12345, info: { test: 'test' })
    worker = Exekutor::Info::Worker.find_by hostname: 'test', pid: 12345
    refute_nil worker
    refute_nil worker.created_at
    refute_nil worker.last_heartbeat_at
    assert_equal "initializing", worker.status
  ensure
    worker&.destroy
  end

  def test_worker_uniqueness
    worker = Exekutor::Info::Worker.create(hostname: 'test', pid: 12345, info: { dummy: true })
    assert_raises(ActiveRecord::RecordNotUnique) { Exekutor::Info::Worker.create(hostname: 'test', pid: 12345, info: { dummy: true }) }
  ensure
    worker&.destroy
  end

  def test_worker_heartbeat
    worker = Exekutor::Info::Worker.create(hostname: 'test', pid: 12345, info: { dummy: true }, last_heartbeat_at: 2.minutes.ago)
    test_start = Time.now
    Timecop.freeze test_start do
      assert worker.heartbeat!
      assert_equal test_start.change(sec: 0), worker.last_heartbeat_at
    end
    Timecop.freeze test_start.change(sec: 59) do
      # Subsequent calls within the same minute should be noops
      refute worker.heartbeat!
    end
    Timecop.freeze test_start.change(sec: 0) + 1.minute do
      assert worker.heartbeat!
      assert_equal test_start.change(sec: 0) + 1.minute, worker.last_heartbeat_at
    end
  ensure
    worker&.destroy
  end

  def test_job
    active_job_id = SecureRandom.uuid
    Exekutor::Job.create!(queue: "test", priority: 1234, active_job_id: active_job_id, payload: { dummy: true })
    job = Exekutor::Job.find_by active_job_id: active_job_id
    refute_nil job
    refute_nil job.status
    refute_nil job.enqueued_at
    refute_nil job.scheduled_at
    assert_equal "pending", job.status
  ensure
    job&.destroy
  end

  def test_release_job
    worker = Exekutor::Info::Worker.create(hostname: 'test', pid: 12345, info: { dummy: true })
    job = Exekutor::Job.create!(queue: "test", priority: 1234, active_job_id: SecureRandom.uuid, payload: { dummy: true }, status: "executing", worker: worker)
    job.release!
    job = Exekutor::Job.find(job.id)
    refute_nil job
    assert_equal 'pending', job.status
    refute job.worker_id
  ensure
    job&.destroy
    worker&.destroy
  end

  def test_reschedule_job
    job = Exekutor::Job.create!(queue: "test", priority: 1234, active_job_id: SecureRandom.uuid, payload: { dummy: true }, status: "failed")
    schedule_at = 1.minute.from_now
    job.reschedule! at: schedule_at
    job = Exekutor::Job.find(job.id)
    assert_equal "pending", job.status
    assert_equal schedule_at, job.scheduled_at
  ensure
    job&.destroy
  end

  def test_discard_job
    job = Exekutor::Job.create!(queue: "test", priority: 1234, active_job_id: SecureRandom.uuid, payload: { dummy: true })
    job.discard!
    assert_equal ["discarded"], Exekutor::Job.where(id: job.id).pluck(:status)
  ensure
    job&.destroy
  end

  def test_error
    job = Exekutor::Job.create!(queue: "test", priority: 1234, active_job_id: SecureRandom.uuid, payload: { dummy: true })
    error = Exekutor::JobError.create!(job: job, error: { class: 'ErrorClass', message: 'Error message' })
    assert job.destroy
    refute Exekutor::JobError.exists? error.id
  end
end
