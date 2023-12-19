# frozen_string_literal: true

module Exekutor
  # @private
  module Internal
    # Reserves jobs to be executed by the current worker
    class Reserver
      # The name to use for the SQL log message
      ACTION_NAME = "Exekutor::Reserve"

      # Creates a new Reserver
      # @param worker_id [String] the id of the worker
      # @param queues [Array<String>] the queues to watch
      def initialize(worker_id, queues: nil, min_priority: nil, max_priority: nil)
        @worker_id = worker_id
        @reserve_filter_sql = build_filter_sql(queues: queues, min_priority: min_priority, max_priority: max_priority)
        @json_serializer = Exekutor.config.load_json_serializer
      end

      # Reserves pending jobs
      # @param limit [Integer] the number of jobs to reserve
      # @return [Array<Hash>,nil] the reserved jobs, or nil if no jobs were reserved
      def reserve(limit)
        return unless limit.positive?

        results = Exekutor::Job.connection.exec_query <<~SQL, ACTION_NAME, [@worker_id, limit], prepare: true
          UPDATE exekutor_jobs SET worker_id = $1, status = 'e' WHERE id IN (
             SELECT id FROM exekutor_jobs
                WHERE scheduled_at <= now() AND "status"='p'#{" AND #{@reserve_filter_sql}" if @reserve_filter_sql}
                ORDER BY priority#{" DESC" if Exekutor.config.inverse_priority?}, scheduled_at, enqueued_at
                FOR UPDATE SKIP LOCKED
                LIMIT $2
          ) RETURNING "id", "payload", "options", "scheduled_at"
        SQL
        return unless results&.length&.positive?

        parse_jobs results
      end

      # Gets the jobs that are assigned to this worker and have an id that is not included in +active_job_ids+
      # @param active_job_ids [Array<String>] The ids of the jobs that should be excluded
      # @return [Array<Hash>] the jobs
      def get_abandoned_jobs(active_job_ids)
        jobs = Exekutor::Job.executing.where(worker_id: @worker_id)
        jobs = jobs.where.not(id: active_job_ids) if active_job_ids.present?
        attrs = %i[id payload options scheduled_at]
        jobs.pluck(*attrs).map { |p| attrs.zip(p).to_h }
      end

      # Gets the earliest scheduled at of all pending jobs in the watched queues
      # @return [Time,nil] The earliest scheduled at, or nil if the queues are empty
      def earliest_scheduled_at
        jobs = Exekutor::Job.pending
        jobs.where! @reserve_filter_sql unless @reserve_filter_sql.nil?
        jobs.minimum(:scheduled_at)
      end

      private

      # Parses jobs from the SQL results
      def parse_jobs(sql_results)
        sql_results.map do |result|
          { id: result["id"],
            payload: parse_json(result["payload"]),
            options: parse_json(result["options"]),
            scheduled_at: result["scheduled_at"] }
        end
      end

      # Parses JSON using the configured serializer
      def parse_json(str)
        @json_serializer.load str unless str.nil?
      end

      # Builds SQL filter for the given queues and priorities
      def build_filter_sql(queues:, min_priority:, max_priority:)
        filters = [
          build_queue_filter_sql(queues),
          build_priority_filter_sql(min_priority, max_priority)
        ]
        filters.compact!
        filters.join(" AND ") unless filters.empty?
      end

      # Builds SQL filter for the given queues
      def build_queue_filter_sql(queues)
        return nil if queues.nil? || (queues.is_a?(Array) && queues.empty?)

        queues = queues.first if queues.is_a?(Array) && queues.one?
        validate_queues! queues

        conditions = if queues.is_a? Array
                       ["queue IN (?)", queues]
                     else
                       ["queue = ?", queues]
                     end
        Exekutor::Job.sanitize_sql_for_conditions conditions
      end

      # Builds SQL filter for the given priorities
      def build_priority_filter_sql(minimum, maximum)
        minimum = coerce_priority(minimum)
        maximum = coerce_priority(maximum)

        conditions = if minimum && maximum
                       ["priority BETWEEN ? AND ?", minimum, maximum]
                     elsif minimum
                       ["priority >= ?", minimum]
                     elsif maximum
                       ["priority <= ?", maximum]
                     end
        Exekutor::Job.sanitize_sql_for_conditions conditions if conditions
      end

      # @return [Integer,nil] returns nil unless +priority+ is between 1 and 32,766
      def coerce_priority(priority)
        priority if priority && (1..32_766).cover?(priority)
      end

      # Raises an error if the queues value is invalid
      # @param queues [String,Symbol,Array<String,Symbol>] the queues to validate
      # @raise [ArgumentError] if the queue is invalid or includes an invalid value
      def validate_queues!(queues)
        case queues
        when Array
          raise ArgumentError, "queues contains an invalid value" unless queues.all? { |queue| valid_queue_name? queue }
        when String, Symbol
          raise ArgumentError, "queue name cannot be empty" unless valid_queue_name? queues
        else
          raise ArgumentError,
                "queues must be nil, a String, Symbol, or an array of Strings or Symbols (Actual: #{queues.class})"
        end
      end

      # @param queue [String,Symbol] the name of a queue
      # @return [Boolean] whether the name is a valid queue name
      def valid_queue_name?(queue)
        (queue.is_a?(String) || queue.is_a?(Symbol)) && queue.present? && queue.length <= Queue::MAX_NAME_LENGTH
      end
    end
  end
end
