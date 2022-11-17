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
        @reserve_now = Concurrent::AtomicBoolean.new false
        @next_job_scheduled_at = Concurrent::AtomicReference.new UNKNOWN
      end

      def start
        return false unless compare_and_set_state :pending, :started

        start_thread
        true
      end

      def stop
        set_state :stopped
        @event.set
      end

      def poll
        raise Exekutor::Error, "Provider is not running" unless running?

        Exekutor.say "[Provider] #Poll"
        @reserve_now.make_true
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

        scheduled_at = @next_job_scheduled_at.update do |current|
          if current == UNKNOWN
            overwrite_unknown || scheduled_at <= Time.now ? scheduled_at : current
          elsif current.nil? || scheduled_at.nil? || current > scheduled_at
            scheduled_at
          else
            current
          end
        end
        if scheduled_at == UNKNOWN
          nil
        else
          @event.set if scheduled_at.present? && scheduled_at <= Time.now
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
            next unless @reserve_now.make_false || polling_enabled? || jobs_pending?

            reserve_and_execute_jobs
          end
        end
        Exekutor.say "[Listener] Providing has ended"
      rescue StandardError => e
        Exekutor.say! "[Provider] Biem! #{e}"
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
        @event.wait timeout if timeout.positive?
      rescue StandardError => err
        Exekutor.say! "[Provider] An error occurred while waiting: #{err}"
      ensure
        throw :shutdown unless running?
        @event.reset
      end

      def reserve_and_execute_jobs
        available_threads = @executor.available_threads
        return unless available_threads.positive?

        jobs = @reserver.reserve available_threads
        jobs&.each(&@executor.method(:post))
        return unless jobs.nil? || jobs.size.to_i < available_threads

        # If we ran out of work, update the earliest scheduled at
        update_earliest_scheduled_at
      end

      def polling_enabled?
        @polling_interval.present?
      end

      def wait_timeout
        next_job_scheduled_at = @next_job_scheduled_at.get

        # Start the very first poll after 1 second
        return 1 if next_job_scheduled_at == UNKNOWN

        max_interval = if polling_enabled?
                         @polling_interval + if @interval_jitter.zero?
                                               0
                                             else
                                               (Kernel.rand - 0.5) * @interval_jitter
                                             end
                       else
                         60
                       end
        if next_job_scheduled_at.nil?
          max_interval
        elsif next_job_scheduled_at <= Time.now
          0
        else
          [next_job_scheduled_at - Time.now, max_interval].min
        end
      end

      def jobs_pending?
        scheduled_at = @next_job_scheduled_at.get
        scheduled_at == UNKNOWN || (scheduled_at && scheduled_at <= Time.now)
      end
    end
  end
end