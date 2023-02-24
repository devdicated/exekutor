# frozen_string_literal: true

module Exekutor
  # The job queue
  class Queue
    # Used when logging the SQL queries
    # @private
    ACTION_NAME = "Exekutor::Enqueue"
    private_constant "ACTION_NAME"

    # Valid range for job priority
    # @private
    VALID_PRIORITIES = (1..32_767).freeze

    # Maximum length for the queue name
    # @private
    MAX_NAME_LENGTH = 63

    # Adds a job to the queue, scheduled to perform immediately
    # @param jobs [Array<ActiveJob::Base>] the jobs to enqueue
    # @return [void]
    def push(*jobs)
      create_records(jobs)
    end

    # Adds a job to the queue, scheduled to be performed at the indicated time
    # @param jobs [Array<ActiveJob::Base>] the jobs to enqueue
    # @param timestamp [Time,Date,Integer,Float] when the job should be performed
    # @return [void]
    def schedule_at(*jobs, timestamp)
      create_records(jobs, scheduled_at: timestamp)
    end

    private

    # Creates {Exekutor::Job} records for the specified jobs, scheduled at the indicated time
    # @param jobs [Array<ActiveJob::Base>] the jobs to enqueue
    # @param scheduled_at [Time,Date,Integer,Float] when the job should be performed
    # @return [void]
    def create_records(jobs, scheduled_at: nil)
      unless jobs.is_a?(Array) && jobs.all? { |job| job.is_a?(ActiveJob::Base) }
        raise ArgumentError, "jobs must be an array with ActiveJob items"
      end

      if scheduled_at.nil?
        scheduled_at = Time.now.to_i
      else
        case scheduled_at
        when Integer, Float
          raise ArgumentError, "scheduled_at must be a valid epoch" unless scheduled_at.positive?
        when Time
          scheduled_at = scheduled_at.to_f
        when Date
          scheduled_at = scheduled_at.at_beginning_of_day.to_f
        else
          raise ArgumentError, "scheduled_at must be an epoch, time, or date"
        end
      end

      json_serializer = Exekutor.config.load_json_serializer

      Internal::Hooks.run :enqueue, jobs do
        if jobs.one?
          Exekutor::Job.connection.exec_query <<~SQL, ACTION_NAME, job_sql_binds(jobs.first, scheduled_at, json_serializer), prepare: true
            INSERT INTO exekutor_jobs ("queue", "priority", "scheduled_at", "active_job_id", "payload", "options") VALUES ($1, $2, to_timestamp($3), $4, $5, $6) RETURNING id;
          SQL
        else
          insert_statements = jobs.map do |job|
            Exekutor::Job.sanitize_sql_for_assignment(
              ["(?, ?, to_timestamp(?), ?, ?::jsonb, ?::jsonb)", *job_sql_binds(job, scheduled_at, json_serializer)]
            )
          end
          Exekutor::Job.connection.insert <<~SQL, ACTION_NAME
            INSERT INTO exekutor_jobs ("queue", "priority", "scheduled_at", "active_job_id", "payload", "options") VALUES #{insert_statements.join(",")}
          SQL
        end
      end
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
        raise Error, "The queue name \"#{job.queue_name}\" is too long, the limit is #{Queue::MAX_NAME_LENGTH} characters"
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

      options = job.exekutor_options.stringify_keys
      if options && options['queue_timeout']
        options['start_execution_before'] = Time.now.to_f + options.delete('queue_timeout').to_f
      end
      options['execution_timeout'] = options['execution_timeout'].to_f if options && options['execution_timeout']

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
