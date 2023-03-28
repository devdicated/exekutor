# frozen_string_literal: true

module Exekutor
  # Helper class to clean up finished jobs and stale workers.
  class Cleanup
    # Purges all workers where the last heartbeat is over the +timeout+ ago.
    # @param timeout [ActiveSupport::Duration,Numeric,Time] the timeout. Default: 4 hours
    # @return [Array<Exekutor::Info::Worker>] the purged workers
    def cleanup_workers(timeout: 4.hours)
      destroy_before = parse_timeout_arg :timeout, timeout
      # TODO: PG-NOTIFY each worker with an EXIT command
      Exekutor::Info::Worker.where(%("last_heartbeat_at"<?), destroy_before).destroy_all
    end

    # Purges all jobs where scheduled at is before +before+. Only purges jobs with the given status, if no status is
    # given all jobs that are not pending are purged.
    # @param before [ActiveSupport::Duration,Numeric,Time] the maximum scheduled at. Default: 48 hours ago
    # @param status [Array<String,Symbol>,String,Symbol] the statuses to purge. Default: All except +:pending+
    # @return [Integer] the number of purged jobs
    def cleanup_jobs(before: 48.hours.ago, status: nil)
      destroy_before = parse_timeout_arg :before, before
      unless [Array, String, Symbol, NilClass].any? { |c| status.is_a? c }
        raise ArgumentError, "Unsupported value for status: #{status.class}"
      end

      jobs = Exekutor::Job.all
      jobs.where!(%("scheduled_at"<?), destroy_before) unless before.nil?
      if status
        jobs.where! status: status
      else
        jobs = jobs.where.not(status: :p)
      end
      jobs.delete_all
    end

    private

    # Converts timout argument to a Time
    # @param name [Symbol,String] the name of the argument
    # @param value [ActiveSupport::Duration,Numeric,Date,Time] the argument to parse
    # @return [Date,Time] The point in time
    def parse_timeout_arg(name, value)
      case value
      when ActiveSupport::Duration
        value.ago
      when Numeric
        value.hours.ago
      when Date, Time
        value
      else
        raise ArgumentError, "Unsupported value for #{name}: #{value.class}"
      end
    end
  end
end
