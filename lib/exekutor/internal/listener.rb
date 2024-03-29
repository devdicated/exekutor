# frozen_string_literal: true

require_relative "executable"

module Exekutor
  # @private
  module Internal
    # Listens for jobs to be executed
    class Listener
      include Executable
      include Logger

      # The PG notification channel for enqueued jobs
      JOB_ENQUEUED_CHANNEL = "exekutor::job_enqueued"
      # The PG notification channel for a worker. Must be formatted with the worker ID.
      PROVIDER_CHANNEL = "exekutor::worker::%s"

      # rubocop:disable Metrics/ParameterLists

      # Creates a new listener
      # @param worker_id [String] the ID of the worker
      # @param queues [Array<String>] the queues to watch
      # @param provider [Provider] the job provider
      # @param pool [ThreadPoolExecutor] the thread pool to use
      # @param wait_timeout [Integer] the time to listen for notifications
      # @param set_db_connection_name [Boolean] whether to set the application name on the DB connection
      def initialize(worker_id:, provider:, pool:, queues: nil, min_priority: nil, max_priority: nil, wait_timeout: 100,
                     set_db_connection_name: false)
        super()
        @config = {
          worker_id: worker_id,
          queues: queues.presence,
          min_priority: min_priority,
          max_priority: max_priority,
          wait_timeout: wait_timeout,
          set_db_connection_name: set_db_connection_name
        }

        @provider = provider
        @pool = pool

        @thread_running = Concurrent::AtomicBoolean.new false
        @listening = Concurrent::AtomicBoolean.new false
      end

      # rubocop:enable Metrics/ParameterLists

      # Starts the listener
      def start
        return false unless compare_and_set_state :pending, :started

        start_thread
        true
      end

      # Stops the listener
      def stop
        self.state = :stopped
        begin
          Exekutor::Job.connection.execute(%(NOTIFY "#{provider_channel}"))
        rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
          # ignored
        end
      end

      private

      # The PG notification channel for a worker
      def provider_channel
        PROVIDER_CHANNEL % @config[:worker_id]
      end

      # @return [Boolean] Whether the job matches the configured queues and priority range
      def job_filter_match?(job_info)
        listening_to_queue?(job_info["q"]) && listening_to_priority?(job_info["p"].to_i)
      end

      # @return [Boolean] Whether this listener is listening to the given queue
      def listening_to_queue?(queue)
        queues = @config[:queues]
        queues.nil? || queues.include?(queue)
      end

      # @return [Boolean] Whether this listener is listening to the given priority
      def listening_to_priority?(priority)
        minimum = @config[:min_priority]
        maximum = @config[:max_priority]
        (minimum.nil? || minimum <= priority) && (maximum.nil? || maximum >= priority)
      end

      # Starts the listener thread
      def start_thread(delay: nil)
        return unless running?

        if delay
          Concurrent::ScheduledTask.execute(delay, executor: @pool) { run }
        else
          @pool.post { run }
        end
      end

      # Sets up the PG notifications and listens for new jobs
      def run
        return unless running? && @thread_running.make_true

        with_pg_connection do |connection|
          connection.exec(%(LISTEN "#{provider_channel}"))
          connection.exec(%(LISTEN "#{JOB_ENQUEUED_CHANNEL}"))
          consecutive_errors.value = 0
          catch(:shutdown) { wait_for_jobs(connection) }
        ensure
          connection.exec("UNLISTEN *")
        end
      rescue StandardError => e
        on_thread_error(e)
      ensure
        @thread_running.make_false
        @listening.make_false
      end

      # Called when an error is raised in #run
      def on_thread_error(error)
        Exekutor.on_fatal_error error, "[Listener] Runtime error!"
        self.state = :crashed if error.is_a? UnsupportedDatabase

        return unless running?

        consecutive_errors.increment
        delay = restart_delay
        logger.info format("Restarting in %0.1f seconds…", delay)
        start_thread delay: delay
      end

      # Listens for jobs. Blocks until the listener is stopped
      def wait_for_jobs(connection)
        while running?
          @listening.make_true
          connection.wait_for_notify(@config[:wait_timeout]) do |channel, _pid, payload|
            throw :shutdown unless running?
            next unless channel == JOB_ENQUEUED_CHANNEL

            job_info = begin
                         JobParser.parse(payload)
                       rescue StandardError => e
                         logger.error e.message
                         nil
                       end
            next unless job_info && job_filter_match?(job_info)

            @provider.update_earliest_scheduled_at(job_info["t"].to_f)
          end
        end
      end

      # Gets a DB connection and removes it from the pool. Sets the application name if +set_db_connection_name+ is
      # true. Closes the connection after yielding it to the given block.
      # (Grabbed from PG adapter for action cable)
      # @yield yields the connection
      # @yieldparam connection [PG::Connection] the DB connection
      def with_pg_connection # :nodoc:
        ar_conn = Exekutor::Job.connection_pool.checkout.tap do |conn|
          DatabaseConnection.ensure_active! conn
          # Action Cable is taking ownership over this database connection, and
          # will perform the necessary cleanup tasks
          Exekutor::Job.connection_pool.remove conn
        end
        # Make sure the connection pool does not hold a reference to this thread
        Exekutor::Job.connection_handler.clear_active_connections!
        pg_conn = ar_conn.raw_connection

        verify!(pg_conn)
        if @config[:set_db_connection_name]
          DatabaseConnection.set_application_name pg_conn, @config[:worker_id], :listener
        end
        yield pg_conn
      ensure
        ar_conn&.disconnect!
      end

      # Verifies the connection
      # @raise [Error] if the connection is not an instance of +PG::Connection+ or is invalid.
      def verify!(pg_conn)
        unless pg_conn.is_a?(PG::Connection)
          raise UnsupportedDatabase,
                "The raw connection of the active record connection adapter must be an instance of PG::Connection"
        end
        true
      end

      # For testing purposes
      def listening?
        @listening.true?
      end

      # Parses a NOTIFY payload to a job
      class JobParser
        JOB_INFO_KEYS = %w[id q p t].freeze

        def self.parse(payload)
          job_info = begin
                       payload.split(";").to_h { |el| el.split(":") }
                     rescue StandardError
                       raise Error, "Invalid notification payload: #{payload}"
                     end
          if (missing_keys = JOB_INFO_KEYS.select { |n| job_info[n].blank? }).present?
            raise Error, "Notification payload is missing #{missing_keys.join(", ")}"
          end

          job_info
        end
      end

      # Raised when an error occurs in the listener.
      class Error < Exekutor::Error; end

      # Raised when the database connection is not an instance of +PG::Connection+.
      class UnsupportedDatabase < Exekutor::Error; end
    end
  end
end
