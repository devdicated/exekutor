module Exekutor
  class Cleanup

    # Purges all workers where the last heartbeat is over the +timeout+ ago.
    # @param timeout [ActiveSupport::Duration,Numeric,Time] the timeout. Default: 4 hours
    # @return [Array<Exekutor::Info::Worker>] the purged workers
    def cleanup_workers(timeout: 4.hours)
      destroy_before = case timeout
                       when ActiveSupport::Duration
                         timeout.ago
                       when Numeric
                         timeout.hours.ago
                       when Date, Time
                         timeout
                       else
                         raise ArgumentError, "Unsupported value for timeout: #{timeout.class}"
                       end
      # TODO PG-NOTIFY each worker with an EXIT command
      Exekutor::Info::Worker.where(%{"last_heartbeat_at"<?}, destroy_before).destroy_all
    end

    # Purges all jobs where scheduled at is before +before+. Only purges jobs with the given status, if no status is
    # given all jobs that are not pending are purged.
    # @param before [ActiveSupport::Duration,Numeric,Time] the maximum scheduled at. Default: 48 hours ago
    # @param status [Array<String,Symbol>,String,Symbol] the statuses to purge. Default: All except +:pending+
    # @return [Integer] the number of purged jobs
    def cleanup_jobs(before: 48.hours.ago, status: nil)
      destroy_before = case before
                       when ActiveSupport::Duration
                         before.ago
                       when Numeric
                         before.hours.ago
                       when Date, Time
                         before
                       else
                         raise ArgumentError, "Unsupported value for before: #{before.class}"
                       end
      unless [Array, String, Symbol].any?(&status.method(:is_a?))
        raise ArgumentError, "Unsupported value for status: #{status.class}"
      end

      jobs = Exekutor::Job.all
      unless before.nil?
        jobs.where!(%{"scheduled_at"<?}, destroy_before)
      end
      if status
        jobs.where! status: status
      else
        jobs = jobs.where.not(status: :p)
      end
      jobs.delete_all
    end

  end
end