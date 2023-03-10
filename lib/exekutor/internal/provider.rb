# frozen_string_literal: true

require_relative "executable"
require_relative "callbacks"

module Exekutor
  # @private
  module Internal
    # Reserves jobs and provides them to an executor
    class Provider
      include Executable, Callbacks, Logger

      define_callbacks :on_queue_empty, freeze: true

      # Represents an unknown value
      UNKNOWN = Object.new.freeze
      private_constant "UNKNOWN"

      # Creates a new provider
      # @param reserver [Reserver] the job reserver
      # @param executor [Executor] the job executor
      # @param pool [ThreadPoolExecutor] the thread pool to use
      # @param polling_interval [Integer] the polling interval
      # @param interval_jitter [Float] the polling interval jitter
      def initialize(reserver:, executor:, pool:, polling_interval: 60,
                     interval_jitter: polling_interval > 1 ? polling_interval * 0.1 : 0)
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

      # Starts the provider.
      def start
        return false unless compare_and_set_state :pending, :started

        # Always poll at startup to fill up threads
        @next_poll_at.set 1.second.from_now
        start_thread
        true
      end

      # Stops the provider
      def stop
        set_state :stopped
        @event.set
      end

      # Makes the provider poll for jobs
      def poll
        raise Exekutor::Error, "Provider is not running" unless running?

        @next_poll_at.set Time.now
        @event.set
      end

      # Updates the timestamp for when the next job is scheduled. Gets the earliest scheduled_at from the DB if no
      # argument is given. Updates the timestamp for the earliest job is a timestamp is given and that timestamp is
      # before the known timestamp. Does nothing if a timestamp is given and the earliest job timestamp is not known.
      # @param scheduled_at [Time,Numeric] the time a job is scheduled at
      # @return [Time] the timestamp for the next job, or +nil+ if the timestamp is unknown or no jobs are pending
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

      # Starts the provision thread
      def start_thread
        @pool.post(&method(:run)) if running?
      end

      # Does the provisioning of jobs to the executor. Blocks until the provider is stopped.
      def run
        return unless running? && @thread_running.make_true
        DatabaseConnection.ensure_active!

        perform_pending_job_updates
        restart_abandoned_jobs
        catch(:shutdown) do
          while running? do
            wait_for_event
            next unless reserve_jobs_now?

            reserve_and_execute_jobs
            consecutive_errors.value = 0
          end
        end
      rescue StandardError => err
        Exekutor.on_fatal_error err, "[Provider] Runtime error!"
        consecutive_errors.increment
        if running?
          delay = restart_delay
          logger.info "Restarting in %0.1f seconds???" % [delay]
          Concurrent::ScheduledTask.execute(delay, executor: @pool, &method(:run))
        end
      ensure
        @thread_running.make_false
      end

      # Waits for any event to happen. An event could be:
      # - The listener was notified of a new job;
      # - The next job is scheduled for the current time;
      # - The polling interval;
      # - A call to {#poll}
      def wait_for_event
        timeout = wait_timeout
        return unless timeout.positive?

        @event.wait timeout
      rescue StandardError => err
        Exekutor.on_fatal_error err, "[Provider] An error occurred while waiting"
      ensure
        throw :shutdown unless running?
        @event.reset
      end

      # Reserves jobs and posts them to the executor
      def reserve_and_execute_jobs
        available_workers = @executor.available_workers
        return unless available_workers.positive?

        jobs = @reserver.reserve available_workers
        unless jobs.nil?
          begin
            logger.debug "Reserved #{jobs.size} jobs"
            jobs.each(&@executor.method(:post))
          rescue Exception # rubocop:disable Lint/RescueException
            # Try to release all jobs before re-raising
            begin
              Exekutor::Job.where(id: jobs.collect { |job| job[:id] }, status: "e")
                           .update_all(status: "p", worker_id: nil)
            rescue # rubocop:disable Lint/RescueStandardError
              # ignored
            end
            raise
          end
        end
        if jobs.nil? || jobs.size.to_i < available_workers
          # If we ran out of work, update the earliest scheduled at
          update_earliest_scheduled_at

          run_callbacks :on, :queue_empty if jobs.nil?

        elsif @next_job_scheduled_at.get == UNKNOWN
          # If the next job timestamp is still unknown, set it to now to indicate there's still work to do
          @next_job_scheduled_at.set Time.now
        end
      end

      def perform_pending_job_updates
        updates = @executor.pending_job_updates
        while (id, attrs = updates.shift).present?
          begin
            if attrs == :destroy
              Exekutor::Job.destroy(id)
            else
              Exekutor::Job.where(id: id).update_all(attrs)
            end
          rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
            unless Exekutor::Job.connection.active?
              # Connection lost again, avoid trying further updates
              return
            end
          end
        end
      end

      # Restarts all jobs that have the 'executing' status but are no longer running. Releases the jobs if the
      # execution thread pool is full.
      def restart_abandoned_jobs
        jobs = @reserver.get_abandoned_jobs(@executor.active_job_ids)
        return if jobs&.size.to_i.zero?

        logger.debug "Restarting #{jobs.size} abandoned job#{"s" if jobs.size > 1}"
        jobs.each(&@executor.method(:post))
      end

      # @return [Boolean] Whether the polling is enabled. Ie. whether a polling interval is set.
      def polling_enabled?
        @polling_interval.present?
      end

      # @return [Numeric] The timeout to wait until the next event
      def wait_timeout
        next_job_scheduled_at = @next_job_scheduled_at.get
        next_job_scheduled_at = nil if next_job_scheduled_at == UNKNOWN

        max_interval = if polling_enabled?
                         @next_poll_at.update do |planned_at|
                           planned_at || (Time.now + polling_interval)
                         end.to_f - Time.now.to_f
                       else
                         60
                       end
        if next_job_scheduled_at.nil? || @executor.available_workers.zero?
          max_interval
        elsif next_job_scheduled_at <= Time.now || max_interval <= 0.001
          0
        else
          # noinspection RubyMismatchedReturnType
          [next_job_scheduled_at - Time.now, max_interval].min
        end
      end

      # @return [Boolean] Whether the `reserver` should be called.
      def reserve_jobs_now?
        next_poll_at = @next_poll_at.get
        if next_poll_at && next_poll_at < Time.now
          @next_poll_at.update { polling_enabled? ? Time.now + polling_interval : nil }
          return true
        end

        next_job_at = @next_job_scheduled_at.get
        next_job_at == UNKNOWN || (next_job_at && next_job_at <= Time.now)
      end

      # Get the polling interval. If a jitter is configured, the interval is reduced or increased by `0.5 * jitter`.
      # @return [Float] The amount of seconds before the next poll
      def polling_interval
        raise "Polling is disabled" unless @polling_interval.present?

        @polling_interval + if @interval_jitter.zero?
                              0
                            else
                              (Kernel.rand - 0.5) * @interval_jitter
                            end
      end
    end
  end
end
