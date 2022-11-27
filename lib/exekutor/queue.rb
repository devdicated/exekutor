# frozen_string_literal: true
module Exekutor
  class Queue
    ACTION_NAME = "Exekutor::Enqueue"

    def push(job)
      create_record(job)
    end

    def schedule_at(job, timestamp)
      create_record(job, scheduled_at: timestamp)
    end

    private

    def create_record(job, scheduled_at: nil)
      raise ArgumentError, "job must be an ActiveJob" unless job.is_a? ActiveJob::Base

      if scheduled_at.nil?
        scheduled_at = Time.now.to_i
      else
        case scheduled_at
        when Integer, Float
          raise ArgumentError, "scheduled_at must be a valid epoch" unless scheduled_at.positive?
        when Time
          scheduled_at = scheduled_at.to_f
        when Date
          scheduled_at = scheduled_at.to_time.to_f
        else
          raise ArgumentError, "scheduled_at must be an epoch, time, or date (was: #{scheduled_at.class})"
        end
      end

      json_serializer = Exekutor.config.json_serializer_class

      Exekutor::Job.connection.exec_query <<~SQL, ACTION_NAME, job_sql_binds(job, scheduled_at, json_serializer), prepare: true
        INSERT INTO exekutor_jobs ("queue", "priority", "scheduled_at", "active_job_id", "payload", "options") VALUES ($1, $2, to_timestamp($3), $4, $5, $6)
      SQL
    end

    def create_records(jobs, scheduled_at: nil)
      raise ArgumentError, "jobs must be an array" unless jobs.is_a? Array

      if scheduled_at.nil?
        scheduled_at = Time.now.to_i
      else
        case scheduled_at
        when Integer
          raise ArgumentError, "scheduled_at must be a valid epoch" unless scheduled_at.positive?
        when Time
          scheduled_at = scheduled_at.to_f
        when Date
          scheduled_at = scheduled_at.to_time.to_f
        else
          raise ArgumentError, "scheduled_at must be an epoch, time, or date"
        end
      end

      json_serializer = Exekutor.config.json_serializer_class

      insert_statements = jobs.map do |job|
        raise ArgumentError "jobs must contain only ActiveJobs" unless job.is_a? ActiveJob::Base

        Exekutor::Job.sanitize_sql_for_assignment(
          ["(?, ?, to_timestamp(?), ?, ?::jsonb, ?::jsonb)", *job_sql_binds(job, scheduled_at, json_serializer)]
        )
      end
      Exekutor::Job.connection.insert <<~SQL, ACTION_NAME
        INSERT INTO exekutor_jobs ("queue", "priority", "scheduled_at", "active_job_id", "payload", "options") VALUES
        #{insert_statements.join(",\n")}
      SQL
    end

    def job_sql_binds(job, scheduled_at, json_serializer)
      options = exekutor_options job
      [
        job.queue_name.presence || Exekutor.config.default_queue_name,
        job_priority(job),
        scheduled_at,
        job.job_id,
        json_serializer.dump(job.serialize),
        options.present? ? json_serializer.dump(options) : nil
      ]
    end

    def exekutor_options(job)
      return nil unless job.respond_to?(:exekutor_options)
      options = job.exekutor_options.stringify_keys
      if options && options['maximum_queue_duration']
        options['start_execution_before'] = Time.now.to_f + options.delete('maximum_queue_duration').to_f
      end
      if options && options['execution_timeout']
        options['execution_timeout'] = options.delete('execution_timeout').to_f
      end
      options
    end

    def job_priority(job)
      priority = job.priority
      if priority.nil?
        priority = Exekutor.config.default_queue_priority
      elsif priority.is_a? Symbol
        priority = Exekutor.config.priority_for_name priority
      end
      unless priority.is_a? Integer
        raise Error, "Job priority must be an integer or a symbol (defined in Exekutor.config.named_priorities)"
      end

      priority
    end

    class Error < StandardError; end

  end
end