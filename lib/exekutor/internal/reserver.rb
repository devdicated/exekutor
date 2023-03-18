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
      def initialize(worker_id, queues)
        @worker_id = worker_id
        @queue_filter_sql = build_queue_filter_sql(queues)
        @json_serializer = Exekutor.config.load_json_serializer
      end

      # Reserves pending jobs
      # @param limit [Integer] the number of jobs to reserve
      # @return [Array<Job>,nil] the reserved jobs, or nil if no jobs were reserved
      def reserve(limit)
        return unless limit.positive?

        results = Exekutor::Job.connection.exec_query <<~SQL, ACTION_NAME, [@worker_id, limit], prepare: true
          UPDATE exekutor_jobs SET worker_id = $1, status = 'e' WHERE id IN (
             SELECT id FROM exekutor_jobs
                WHERE scheduled_at <= now() AND "status"='p' #{@queue_filter_sql}
                ORDER BY priority, scheduled_at, enqueued_at
                FOR UPDATE SKIP LOCKED
                LIMIT $2
          ) RETURNING "id", "payload", "options", "scheduled_at"
        SQL
        return unless results&.length&.positive?

        parse_jobs results
      end

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
        jobs.where! @queue_filter_sql.gsub(/^\s*AND\s+/, "") unless @queue_filter_sql.nil?
        jobs.minimum(:scheduled_at)
      end

      private

      # Parses jobs from the SQL results
      def parse_jobs(sql_results)
        sql_results.map do |result|
          { id: result["id"],
            payload: parse_json(result["payload"]),
            options: parse_json(result["options"]),
            scheduled_at: result['scheduled_at'] }
        end
      end

      # Parses JSON using the configured serializer
      def parse_json(str)
        @json_serializer.load str unless str.nil?
      end

      # Builds SQL filter for the given queues
      def build_queue_filter_sql(queues)
        return nil if queues.nil? || (queues.is_a?(Array) && queues.empty?)
        unless queues.is_a?(String) || queues.is_a?(Symbol) || queues.is_a?(Array)
          raise ArgumentError, "queues must be nil, a String, Symbol, or an array of Strings or Symbols"
        end

        queues = queues.first if queues.is_a?(Array) && queues.one?
        if queues.is_a? Array
          unless queues.all? { |q| (q.is_a?(String) || q.is_a?(Symbol)) && !q.blank? }
            raise ArgumentError, "queues contains an invalid value"
          end

          Exekutor::Job.sanitize_sql_for_conditions(["AND queue IN (?)", queues])
        else
          raise ArgumentError, "queue name cannot be empty" if queues.blank?

          Exekutor::Job.sanitize_sql_for_conditions(["AND queue = ?", queues])
        end
      end

    end
  end
end

