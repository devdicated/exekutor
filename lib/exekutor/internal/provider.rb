# frozen_string_literal: true

require_relative "executable"
require_relative "callbacks"

module Exekutor
  # @private
  module Internal
    # Reserves jobs and provides them to an executor
    class Provider
      include Logger
      include Callbacks
      include Executable

      define_callbacks :on_queue_empty, freeze: true

      # Represents an unknown value
      UNKNOWN = Object.new.freeze
      private_constant :UNKNOWN

      MAX_WAIT_TIMEOUT = 300
      private_constant :MAX_WAIT_TIMEOUT

      # Creates a new provider
      # @param reserver [Reserver] the job reserver
      # @param executor [Executor] the job executor
      # @param pool [ThreadPoolExecutor] the thread pool to use
      # @param polling_interval [Integer] the polling interval
      # @param interval_jitter [Float] the polling interval jitter
      def initialize(reserver:, executor:, pool:, polling_interval: 60,
                     interval_jitter: polling_interval.to_i > 1 ? polling_interval * 0.1 : 0)
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

        # Always poll at startup to fill up threads, use small jitter so workers started at the same time dont hit
        # the db at the same time
        @next_poll_at.set (1 + (2 * Kernel.rand)).seconds.from_now.to_f
        start_thread
        true
      end

      # Stops the provider
      def stop
        self.state = :stopped
        @event.set
      end

      # Makes the provider poll for jobs
      def poll
        raise Exekutor::Error, "Provider is not running" unless running?

        @next_poll_at.set Time.now.to_f
        @event.set
      end

      # Updates the timestamp for when the next job is scheduled. Gets the earliest scheduled_at from the DB if no
      # argument is given. Updates the timestamp for the earliest job is a timestamp is given and that timestamp is
      # before the known timestamp. Does nothing if a timestamp is given and the earliest job timestamp is not known.
      # @param scheduled_at [Time,Numeric] the time a job is scheduled at
      # @return [Float,nil] the timestamp for the next job, or +nil+ if the timestamp is unknown or no jobs are pending
      def update_earliest_scheduled_at(scheduled_at = UNKNOWN)
        scheduled_at = scheduled_at.to_f if scheduled_at.is_a? Time
        unless scheduled_at == UNKNOWN || scheduled_at.is_a?(Numeric)
          raise ArgumentError, "scheduled_at must be a Time or Numeric"
        end

        changed = false
        earliest_scheduled_at = @next_job_scheduled_at.update do |current|
          earliest = ScheduledAtComparer.determine_earliest(current, scheduled_at, @reserver)
          changed = earliest != current
          earliest
        end

        if earliest_scheduled_at == UNKNOWN
          nil
        else
          @event.set if changed && earliest_scheduled_at.present?
          earliest_scheduled_at
        end
      end

      private

      # Starts the provision thread
      def start_thread(delay: nil)
        return unless running?

        if delay
          Concurrent::ScheduledTask.execute(delay, executor: @pool) { run }
        else
          @pool.post { run }
        end
      end

      # Does the provisioning of jobs to the executor. Blocks until the provider is stopped.
      def run
        return unless running? && @thread_running.make_true

        DatabaseConnection.ensure_active!
        perform_pending_job_updates
        restart_abandoned_jobs
        catch(:shutdown) do
          while running?
            wait_for_event
            next unless reserve_jobs_now?

            reserve_and_execute_jobs
            consecutive_errors.value = 0
          end
        end
      rescue StandardError => e
        on_thread_error(e)
      ensure
        BaseRecord.connection_pool.release_connection
        @thread_running.make_false
      end

      # Called when an error is raised in #run
      def on_thread_error(error)
        Exekutor.on_fatal_error error, "[Provider] Runtime error!"
        return unless running?

        consecutive_errors.increment
        delay = restart_delay
        logger.info format("Restarting in %0.1f seconds…", delay)
        start_thread delay: delay
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
      rescue StandardError => e
        Exekutor.on_fatal_error e, "[Provider] An error occurred while waiting"
        sleep 0.1 if running?
      ensure
        throw :shutdown unless running?
        @event.reset
      end

      # Reserves jobs and posts them to the executor
      def reserve_and_execute_jobs
        available_workers = @executor.available_threads
        return unless available_workers.positive?

        jobs = @reserver.reserve available_workers
        execute_jobs jobs unless jobs.nil?

        if jobs.nil? || jobs.size.to_i < available_workers
          # If we ran out of work, update the earliest scheduled at
          update_earliest_scheduled_at

          run_callbacks :on, :queue_empty if jobs.nil?

        elsif @next_job_scheduled_at.get == UNKNOWN
          # If the next job timestamp is still unknown, set it to now to indicate there's still work to do
          @next_job_scheduled_at.set Time.now.to_f
        end
      end

      # Posts the given jobs to the executor thread pool
      # @param jobs [Array] the jobs to execute
      def execute_jobs(jobs)
        logger.debug "Reserved #{jobs.size} job(s)"
        jobs.each { |job| @executor.post(job) }
      rescue Exception # rubocop:disable Lint/RescueException
        # Try to release all jobs before re-raising
        begin
          Exekutor::Job.where(id: jobs.pluck(:id), status: "e")
                       .update_all(status: "p", worker_id: nil)
        rescue StandardError
          # ignored
        end
        raise
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
              # Connection lost again, requeue update and avoid trying further updates
              updates[id] ||= attrs
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

        logger.info "Restarting #{jobs.size} abandoned job#{"s" if jobs.size > 1}"
        jobs.each { |job| @executor.post(job) }
      end

      # @return [Boolean] Whether the polling is enabled. Ie. whether a polling interval is set.
      def polling_enabled?
        @polling_interval.present?
      end

      # @return [Float,nil] the 'scheduled at' value for the next job, or nil if unknown or if there is no pending job
      def next_job_scheduled_at
        at = @next_job_scheduled_at.get
        if at == UNKNOWN
          nil
        else
          # noinspection RubyMismatchedReturnType
          at
        end
      end

      # @return [Float,nil] When the next poll is scheduled, or nil if polling is disabled
      def next_poll_scheduled_at
        if polling_enabled?
          @next_poll_at.update { |planned_at| planned_at || (Time.now.to_f + polling_interval) }
        else
          # noinspection RubyMismatchedReturnType
          @next_poll_at.get
        end
      end

      # @return [Numeric] The timeout to wait until the next event
      def wait_timeout
        return MAX_WAIT_TIMEOUT if @executor.available_threads.zero?

        next_job_at = next_job_scheduled_at
        next_poll_at = next_poll_scheduled_at

        timeout = [MAX_WAIT_TIMEOUT].tap do |timeouts|
          # noinspection RubyMismatchedArgumentType
          timeouts.append next_job_at - Time.now.to_f if next_job_at
          # noinspection RubyMismatchedArgumentType
          timeouts.append next_poll_at - Time.now.to_f if next_poll_at
        end.min

        if timeout <= 0.001
          0
        else
          # noinspection RubyMismatchedReturnType
          timeout
        end
      end

      # @return [Boolean] Whether the `reserver` should be called.
      def reserve_jobs_now?
        next_poll_at = next_poll_scheduled_at
        if next_poll_at && next_poll_at - Time.now.to_f <= 0.001
          @next_poll_at.update { Time.now.to_f + polling_interval if polling_enabled? }
          return true
        end

        next_job_at = next_job_scheduled_at
        next_job_at && next_job_at <= Time.now.to_f
      end

      # @return [Float] Gets the polling interval jitter
      def polling_interval_jitter
        @interval_jitter
      end

      # Get the polling interval. If a jitter is configured, the interval is reduced or increased by `0.5 * jitter`.
      # @return [Float] The amount of seconds before the next poll
      def polling_interval
        raise "Polling is disabled" if @polling_interval.blank?

        @polling_interval + if polling_interval_jitter.zero?
                              0
                            else
                              (Kernel.rand - 0.5) * polling_interval_jitter
                            end
      end

      # Abstraction to determine earliest out of 2 scheduled at timestamps
      class ScheduledAtComparer
        def self.determine_earliest(current_value, other_value, reserver)
          if other_value == UNKNOWN
            # Fetch the value from the db
            reserver.earliest_scheduled_at&.to_f
          elsif current_value == UNKNOWN
            # We don't know the value yet, don't use the given value as earliest unless work is scheduled immediately
            other_value > Time.now.to_f ? UNKNOWN : other_value
          elsif current_value.nil? || current_value > other_value
            # The given value is earlier than the known value
            other_value
          else
            # No changes
            current_value
          end
        end
      end

      private_constant :ScheduledAtComparer
    end
  end
end
