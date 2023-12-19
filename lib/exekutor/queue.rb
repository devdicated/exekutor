# frozen_string_literal: true

module Exekutor
  # The job queue
  class Queue
    # Used when logging the SQL queries
    # @private
    ACTION_NAME = "Exekutor::Enqueue"
    private_constant :ACTION_NAME

    # Valid range for job priority
    # @private
    VALID_PRIORITIES = (1..32_767).freeze

    # Maximum length for the queue name
    # @private
    MAX_NAME_LENGTH = 63

    # Adds a job to the queue, scheduled to perform immediately
    # @param jobs [ActiveJob::Base,Array<ActiveJob::Base>] the jobs to enqueue
    # @return [Integer] the number of enqueued jobs
    def push(jobs)
      create_records Array.wrap(jobs)
    end

    # Adds a job to the queue, scheduled to be performed at the indicated time
    # @param jobs [ActiveJob::Base,Array<ActiveJob::Base>] the jobs to enqueue
    # @param timestamp [Time,Date,Integer,Float] when the job should be performed
    # @return [Integer] the number of enqueued jobs
    def schedule_at(jobs, timestamp)
      create_records(Array.wrap(jobs), scheduled_at: timestamp)
    end

    private

    # Creates {Exekutor::Job} records for the specified jobs, scheduled at the indicated time
    # @param jobs [Array<ActiveJob::Base>] the jobs to enqueue
    # @param scheduled_at [Time,Date,Integer,Float] when the job should be performed
    # @return [void]
    def create_records(jobs, scheduled_at: nil)
      raise ArgumentError, "jobs must be an array with ActiveJob items (Actual: #{jobs.class})" unless jobs.is_a?(Array)

      unless jobs.all?(ActiveJob::Base)
        raise ArgumentError, "jobs must be an array with ActiveJob items (Found: #{
          jobs.map { |job| job.class unless job.is_a? ActiveJob::Base }.compact.join(", ")
        })"
      end

      scheduled_at = parse_scheduled_at(scheduled_at)
      json_serializer = Exekutor.config.load_json_serializer

      inserted_records = nil
      Internal::Hooks.run :enqueue, jobs do
        inserted_records = insert_job_records(jobs, scheduled_at, json_serializer)
      end
      inserted_records
    end

    # Converts the given value to an epoch timestamp. Returns the current epoch timestamp if the given value is nil
    # @param scheduled_at [nil,Numeric,Time,Date] The timestamp to convert to an epoch timestamp
    # @return [Float,Integer] The epoch equivalent of +scheduled_at+
    def parse_scheduled_at(scheduled_at)
      if scheduled_at.nil?
        Time.now.to_i
      else
        case scheduled_at
        when Integer, Float
          raise ArgumentError, "scheduled_at must be a valid epoch" unless scheduled_at.positive?

          scheduled_at
        when Time
          scheduled_at.to_f
        when Date
          scheduled_at.at_beginning_of_day.to_f
        else
          raise ArgumentError, "scheduled_at must be an epoch, time, or date"
        end
      end
    end

    # Fires off an INSERT INTO query for the given jobs
    # @param jobs [Array<ActiveJob::Base>] the jobs to insert
    # @param scheduled_at [Integer,Float] the scheduled execution time for the jobs as an epoch timestamp
    # @param json_serializer [#dump] the serializer to use to convert hashes into JSON
    def insert_job_records(jobs, scheduled_at, json_serializer)
      if jobs.one?
        insert_singular_job(jobs.first, json_serializer, scheduled_at)
      else
        insert_statements = jobs.map do |job|
          Exekutor::Job.sanitize_sql_for_assignment(
            ["(?, ?, to_timestamp(?), ?, ?::jsonb, ?::jsonb)", *job_sql_binds(job, scheduled_at, json_serializer)]
          )
        end
        begin
          pg_result = Exekutor::Job.connection.execute <<~SQL, ACTION_NAME
            INSERT INTO exekutor_jobs ("queue", "priority", "scheduled_at", "active_job_id", "payload", "options") VALUES #{insert_statements.join(",")}
          SQL
          inserted_records = pg_result.cmd_tuples
        ensure
          pg_result.clear
        end
        inserted_records
      end
    end

    # Fires off an INSERT INTO query for the given job using a prepared statement
    # @param job [ActiveJob::Base] the job to insert
    # @param scheduled_at [Integer,Float] the scheduled execution time for the jobs as an epoch timestamp
    # @param json_serializer [#dump] the serializer to use to convert hashes into JSON
    def insert_singular_job(job, json_serializer, scheduled_at)
      sql_binds = job_sql_binds(job, scheduled_at, json_serializer)
      ar_result = Exekutor::Job.connection.exec_query <<~SQL, ACTION_NAME, sql_binds, prepare: true
        INSERT INTO exekutor_jobs ("queue", "priority", "scheduled_at", "active_job_id", "payload", "options") VALUES ($1, $2, to_timestamp($3), $4, $5, $6) RETURNING id;
      SQL
      ar_result.length
    end

    # Converts the specified job to SQL bind parameters to insert it into the database
    # @param job [ActiveJob::Base] the job to insert
    # @param scheduled_at [Float] the epoch timestamp for when the job should be executed
    # @param json_serializer [#dump] the serializer to use to convert hashes into JSON
    # @return [Array] the SQL bind parameters for inserting the specified job
    def job_sql_binds(job, scheduled_at, json_serializer)
      if job.queue_name.blank?
        raise Error, "The queue must be set"
      elsif job.queue_name && job.queue_name.length > Queue::MAX_NAME_LENGTH
        raise Error,
              "The queue name \"#{job.queue_name}\" is too long, the limit is #{Queue::MAX_NAME_LENGTH} characters"
      end

      options = exekutor_options job
      [
        job.queue_name.presence,
        job_priority(job),
        scheduled_at,
        job.job_id,
        json_serializer.dump(job.serialize),
        options.present? ? json_serializer.dump(options) : nil
      ]
    end

    # Get the exekutor options for the specified job.
    # @param job [ActiveJob::Base] the job to get the options for
    # @return [Hash<String,Object>] the exekutor options
    def exekutor_options(job)
      return nil unless job.respond_to?(:exekutor_options)

      options = job.exekutor_options&.stringify_keys
      if options && options["queue_timeout"]
        options["start_execution_before"] = Time.now.to_f + options.delete("queue_timeout").to_f
      end
      options["execution_timeout"] = options["execution_timeout"].to_f if options && options["execution_timeout"]

      options
    end

    # Get the priority for the specified job.
    # @param job [ActiveJob::Base] the job to get the priority for
    # @return [Integer] the priority
    def job_priority(job)
      priority = job.priority
      if priority.is_a? Integer
        unless VALID_PRIORITIES.include? priority
          raise Error, <<~MESSAGE
            Job priority must be between #{VALID_PRIORITIES.begin} and #{VALID_PRIORITIES.end} (actual: #{priority})
          MESSAGE
        end

        priority
      elsif priority.nil?
        Exekutor.config.default_queue_priority
      else
        raise Error, "Job priority must be an Integer or nil"
      end
    end

    # Default error for queueing problems
    class Error < Exekutor::Error; end
  end
end
