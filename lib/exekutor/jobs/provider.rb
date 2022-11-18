# frozen_string_literal: true
require 'exekutor/executable'

module Exekutor
  module Jobs
    class Provider
      include Executable

      UNKNOWN = Object.new.freeze

      def initialize(reserver:, executor:, pool:, polling_interval:, interval_jitter: polling_interval > 1 ? polling_interval * 0.1 : 0)
        super()
        @reserver = reserver
        @executor = executor
        @pool = pool

        @polling_interval = polling_interval.freeze
        @interval_jitter = interval_jitter.to_f.freeze

        @event = Concurrent::Event.new
        @thread_running = Concurrent::AtomicBoolean.new false

        @next_job_scheduled_at = Concurrent::AtomicReference.new UNKNOWN
        @next_poll_at = Concurrent::AtomicReference.new nil
      end

      def start
        return false unless compare_and_set_state :pending, :started

        # Always poll at startup to fill up threads
        @next_poll_at.set 1.second.from_now
        start_thread
        true
      end

      def stop
        set_state :stopped
        @event.set
      end

      def poll
        raise Exekutor::Error, "Provider is not running" unless running?

        @next_poll_at.set Time.now
        @event.set
      end

      def update_earliest_scheduled_at(scheduled_at = UNKNOWN)
        overwrite_unknown = false
        case scheduled_at
        when UNKNOWN
          # If we fetch the value from the DB, we can safely overwrite the UNKNOWN value
          overwrite_unknown = true
          scheduled_at = @reserver.earliest_scheduled_at
        when Numeric
          scheduled_at = Time.at(scheduled_at)
        when Time
          #  All good
        else
          raise ArgumentError, "scheduled_at must be a Time or Numeric"
        end

        updated = false
        scheduled_at = @next_job_scheduled_at.update do |current|
          if current == UNKNOWN
            if overwrite_unknown || scheduled_at <= Time.now
              updated = true
              scheduled_at
            else
              current
            end
          elsif current.nil? || scheduled_at.nil? || current > scheduled_at
            updated = true
            scheduled_at
          else
            current
          end
        end
        if scheduled_at == UNKNOWN
          nil
        else
          @event.set if updated && scheduled_at.present?
          scheduled_at
        end
      end

      private

      def start_thread
        @pool.post(&method(:run)) if running?
      end

      def run
        return unless running? && @thread_running.make_true

        Exekutor.say "[Provider] Providing has started"
        catch(:shutdown) do
          while running? do
            wait_for_event
            next unless reserve_jobs_now?

            reserve_and_execute_jobs
          end
        end
        Exekutor.say "[Provider] Providing has ended"
      rescue StandardError => err
        Exekutor.print_error err, "[Provider] Runtime error!"
        # TODO crash if too many failures
        if running?
          Exekutor.say "[Provider] Restarting in 10 seconds…"
          Concurrent::ScheduledTask.execute(10.0, executor: @pool, &method(:run))
        end
      ensure
        @thread_running.make_false
      end

      def wait_for_event
        timeout = wait_timeout
        return unless timeout.positive?

        @event.wait timeout
      rescue StandardError => err
        Exekutor.print_error err, "[Provider] An error occurred while waiting"
      ensure
        throw :shutdown unless running?
        @event.reset
      end

      def reserve_and_execute_jobs
        available_threads = @executor.available_threads
        return unless available_threads.positive?

        jobs = @reserver.reserve available_threads
        Exekutor.say "[Provider] Reserved #{jobs.size.to_i} jobs" unless jobs.nil?
        jobs&.each(&@executor.method(:post))

        if jobs.nil? || jobs.size.to_i < available_threads
          # If we ran out of work, update the earliest scheduled at
          update_earliest_scheduled_at

          # TODO worker.heartbeat!

        elsif @next_job_scheduled_at.get == UNKNOWN
          # If the next job timestamp is still unknown, set it to now to indicate there's still work to do
          @next_job_scheduled_at.set Time.now
        end
      end

      def polling_enabled?
        @polling_interval.present?
      end

      def wait_timeout
        next_job_scheduled_at = @next_job_scheduled_at.get
        next_job_scheduled_at = nil if next_job_scheduled_at == UNKNOWN

        max_interval = if polling_enabled?
                         @next_poll_at.update do |planned_at|
                           planned_at || (Time.now + get_polling_interval)
                         end.to_f - Time.now.to_f
                       else
                         60
                       end
        if next_job_scheduled_at.nil? || @executor.available_threads.zero?
          max_interval
        elsif next_job_scheduled_at <= Time.now || max_interval <= 0.001
          0
        else
          [next_job_scheduled_at - Time.now, max_interval].min
        end
      end

      def reserve_jobs_now?
        next_poll_at = @next_poll_at.get
        if next_poll_at && next_poll_at < Time.now
          @next_poll_at.update do
            if polling_enabled?
              Time.now + get_polling_interval
            else
              nil
            end
          end
          return true
        end

        next_job_at = @next_job_scheduled_at.get
        next_job_at == UNKNOWN || (next_job_at && next_job_at <= Time.now)
      end

      def get_polling_interval
        raise "Polling is disabled" unless @polling_interval.present?
        @polling_interval + if @interval_jitter.zero?
                              0
                            else
                              (Kernel.rand - 0.5) * @interval_jitter
                            end
      end

      def jobs_pending?
      end
    end
  end
end