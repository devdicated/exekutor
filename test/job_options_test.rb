# frozen_string_literal: true

require "test_helper"
require_relative "fixtures/test_jobs"

class JobOptionsTest < Minitest::Test
  attr_reader :job

  def setup
    super
    @job = TestJobs::WithOptions
  end

  def test_set_options
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with(kind_of(TestJobs::WithOptions)) { |job| enqueued_job = job }

    TestJobs::WithOptions.set(queue_timeout: 1.hour, execution_timeout: 1.minute).perform_later

    refute_nil enqueued_job
    assert_equal 1.hour, enqueued_job.exekutor_options[:queue_timeout]
    assert_equal 1.minute, enqueued_job.exekutor_options[:execution_timeout]
  end

  def test_class_options
    enqueued_job = nil
    ActiveJob::Base.queue_adapter.expects(:enqueue).with(kind_of(TestJobs::WithOptions)) { |job| enqueued_job = job }

    job_class = Class.new(ActiveJob::Base) do
      include Exekutor::JobOptions
      exekutor_options queue_timeout: 1.hour, execution_timeout: 1.minute
    end
    job_class.perform_later

    refute_nil enqueued_job
    assert_equal 1.hour, enqueued_job.exekutor_options[:queue_timeout]
    assert_equal 1.minute, enqueued_job.exekutor_options[:execution_timeout]
  end

  def test_invalid_options
    assert_raises(::Exekutor::JobOptions::InvalidOption) { TestJobs::WithOptions.exekutor_options(invalid_option: "invalid value") }
  end
end
