# frozen_string_literal: true
module Exekutor
  module Jobs
    class Listener
      include Executable

      JOB_ENQUEUED_CHANNEL = "exekutor::job_enqueued"
      PROVIDER_CHANNEL = "exekutor::worker::%s"

      def initialize(worker_id:, queues:, provider:, pool:, wait_timeout: 60, set_connection_application_name: false)
        super()
        @config = {
          worker_id: worker_id,
          queues: queues || [],
          wait_timeout: wait_timeout,
          set_connection_application_name: set_connection_application_name
        }

        @provider = provider
        @pool = pool

        @thread_running = Concurrent::AtomicBoolean.new false
      end

      def start
        return false unless compare_and_set_state :pending, :started

        start_thread
        true
      end

      def stop
        set_state :stopped
        Exekutor::Job.connection.execute(%(NOTIFY "#{provider_channel}"))
      end

      private

      def provider_channel
        PROVIDER_CHANNEL % @config[:worker_id]
      end

      def listening_to_queue?(queue)
        queues = @config[:queues]
        queues.nil? || queues.empty? || queues.include?(queue)
      end

      def start_thread
        @pool.post(&method(:run)) if running?
      end

      def run
        return unless running? && @thread_running.make_true

        Exekutor.say "[Listener] Listening has started"
        with_pg_connection do |connection|
          begin
            connection.exec(%(LISTEN "#{provider_channel}"))
            connection.exec(%(LISTEN "#{JOB_ENQUEUED_CHANNEL}"))
            catch(:shutdown) { wait_for_jobs(connection) }
          ensure
            connection.exec("UNLISTEN *")
          end
        end
        Exekutor.say "[Listener] Listening has ended"
      rescue StandardError => err
        Exekutor.print_error err, "[Listener] Runtime error!"
        # TODO crash if too many failures
        if running?
          Exekutor.say "[Listener] Restarting in 10 seconds…"
          Concurrent::ScheduledTask.execute(10.0, executor: @pool, &method(:run))
        end
      ensure
        @thread_running.make_false
      end

      def wait_for_jobs(connection)
        while running?
          connection.wait_for_notify(@config[:wait_timeout]) do |channel, _pid, payload|
            throw :shutdown unless running?
            next unless channel == JOB_ENQUEUED_CHANNEL

            job_info = begin
                         payload.split(";").map { |el| el.split(":") }.to_h
                       rescue
                         Exekutor.say! "[Listener] Invalid notification payload: #{payload}"
                         next
                       end
            unless %w[id q t].all? { |n| job_info[n].include? }
              Exekutor.say! "[Listener] Notification payload is missing #{%w[id q t].select { |n| job_info[n].blank? }.join(", ")}"
              next
            end
            next unless listening_to_queue? job_info["q"]

            scheduled_at = job_info["t"].to_f
            @provider.update_earliest_scheduled_at(scheduled_at)
          end
        end
      end

      # Grabbed from PG adapter for action cable
      def with_pg_connection # :nodoc:
        ar_conn = Exekutor::Job.connection_pool.checkout.tap do |conn|
          # Action Cable is taking ownership over this database connection, and
          # will perform the necessary cleanup tasks
          ActiveRecord::Base.connection_pool.remove(conn)
        end
        pg_conn = ar_conn.raw_connection

        verify!(pg_conn)
        if @config[:set_connection_application_name]
          Exekutor::Connection.set_application_name pg_conn, @config[:worker_id], :listener
        end
        yield pg_conn
      ensure
        ar_conn.disconnect!
      end

      def verify!(pg_conn)
        unless pg_conn.is_a?(PG::Connection)
          raise Error, "The Active Record database must be PostgreSQL in order to use the listener"
        end
        #   TODO check connection status
      end

      class Error < StandardError; end
    end
  end
end
