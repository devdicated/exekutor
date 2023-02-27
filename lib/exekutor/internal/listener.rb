# frozen_string_literal: true

require_relative "executable"

module Exekutor
  # @private
  module Internal
    # Listens for jobs to be executed
    class Listener
      include Executable, Logger

      # The PG notification channel for enqueued jobs
      JOB_ENQUEUED_CHANNEL = "exekutor::job_enqueued"
      # The PG notification channel for a worker. Must be formatted with the worker ID.
      PROVIDER_CHANNEL = "exekutor::worker::%s"

      # Creates a new listener
      # @param worker_id [String] the ID of the worker
      # @param queues [Array<String>] the queues to watch
      # @param provider [Provider] the job provider
      # @param pool [ThreadPoolExecutor] the thread pool to use
      # @param wait_timeout [Integer] the time to listen for notifications
      # @param set_db_connection_name [Boolean] whether to set the application name on the DB connection
      def initialize(worker_id:, queues: nil, provider:, pool:, wait_timeout: 60, set_db_connection_name: false)
        super()
        @config = {
          worker_id: worker_id,
          queues: queues || [],
          wait_timeout: wait_timeout,
          set_db_connection_name: set_db_connection_name
        }

        @provider = provider
        @pool = pool

        @thread_running = Concurrent::AtomicBoolean.new false
      end

      # Starts the listener
      def start
        return false unless compare_and_set_state :pending, :started

        start_thread
        true
      end

      # Stops the listener
      def stop
        set_state :stopped
        begin
          Exekutor::Job.connection.execute(%(NOTIFY "#{provider_channel}"))
        rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
          #ignored
        end
      end

      private

      # The PG notification channel for a worker
      def provider_channel
        PROVIDER_CHANNEL % @config[:worker_id]
      end

      # Whether this listener is listening to the given queue
      # @return [Boolean]
      def listening_to_queue?(queue)
        queues = @config[:queues]
        queues.nil? || queues.empty? || queues.include?(queue)
      end

      # Starts the listener thread
      def start_thread
        @pool.post(&method(:run)) if running?
      end

      # Sets up the PG notifications and listens for new jobs
      def run
        return unless running? && @thread_running.make_true

        with_pg_connection do |connection|
          begin
            connection.exec(%(LISTEN "#{provider_channel}"))
            connection.exec(%(LISTEN "#{JOB_ENQUEUED_CHANNEL}"))
            consecutive_errors.value = 0
            catch(:shutdown) { wait_for_jobs(connection) }
          ensure
            connection.exec("UNLISTEN *")
          end
        end
      rescue StandardError => err
        Exekutor.on_fatal_error err, "[Listener] Runtime error!"
        consecutive_errors.increment
        if running?
          delay = restart_delay
          logger.info "Restarting in %0.1f seconds…" % [delay]
          Concurrent::ScheduledTask.execute(delay, executor: @pool, &method(:run))
        end
      ensure
        @thread_running.make_false
      end

      # Listens for jobs. Blocks until the listener is stopped
      def wait_for_jobs(connection)
        while running?
          connection.wait_for_notify(@config[:wait_timeout]) do |channel, _pid, payload|
            throw :shutdown unless running?
            next unless channel == JOB_ENQUEUED_CHANNEL

            job_info = begin
                         payload.split(";").map { |el| el.split(":") }.to_h
                       rescue
                         logger.error "Invalid notification payload: #{payload}"
                         next
                       end
            unless %w[id q t].all? { |n| job_info[n].present? }
              logger.error "[Listener] Notification payload is missing #{%w[id q t].select { |n| job_info[n].blank? }.join(", ")}"
              next
            end
            next unless listening_to_queue? job_info["q"]

            scheduled_at = job_info["t"].to_f
            @provider.update_earliest_scheduled_at(scheduled_at)
          end
        end
      end

      # Gets a DB connection and removes it from the pool. Sets the application name if +set_db_connection_name+ is true.
      # Closes the connection after yielding it to the given block.
      # (Grabbed from PG adapter for action cable)
      # @yield yields the connection
      # @yieldparam connection [PG::Connection] the DB connection
      def with_pg_connection # :nodoc:
        ar_conn = Exekutor::Job.connection_pool.checkout.tap do |conn|
          # Action Cable is taking ownership over this database connection, and
          # will perform the necessary cleanup tasks
          ActiveRecord::Base.connection_pool.remove(conn)
        end
        pg_conn = ar_conn.raw_connection

        verify!(pg_conn)
        if @config[:set_db_connection_name]
          DatabaseConnection.set_application_name pg_conn, @config[:worker_id], :listener
        end
        yield pg_conn
      ensure
        ar_conn.disconnect!
      end

      # Verifies the connection
      # @raise [Error] if the connection is not an instance of +PG::Connection+ or is invalid.
      def verify!(pg_conn)
        unless pg_conn.is_a?(PG::Connection)
          raise Error, "The Active Record database must be PostgreSQL in order to use the listener"
        end
        #   TODO check connection status
      end

      # Raised when an error occurs in the listener.
      class Error < Exekutor::Error; end
    end
  end
end
