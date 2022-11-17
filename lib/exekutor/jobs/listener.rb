# frozen_string_literal: true
module Exekutor
  module Jobs
    class Listener
      include Executable

      CHANNEL = "exekutor::job_enqueued"
      PROVIDER_CHANNEL = "exekutor::worker::%s"

      def initialize(worker_id:, queues:, provider:, pool:, wait_timeout: 60)
        super()
        @worker_id = worker_id
        @provider = provider
        @queues = queues || []
        @pool = pool
        @wait_timeout = wait_timeout

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
        PROVIDER_CHANNEL % @worker_id
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
            connection.exec(%(LISTEN "#{CHANNEL}"))
            catch(:shutdown) { wait_for_jobs(connection) }
          ensure
            connection.exec("UNLISTEN *")
          end
        end
        Exekutor.say "[Listener] Listening has ended"
      rescue StandardError => e
        Exekutor.say! "[Listener] Biem! #{e}"
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
          job_info = nil
          ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
            connection.wait_for_notify(@wait_timeout) do |channel, _pid, payload|
              throw :shutdown unless running?
              next unless channel == CHANNEL

              job_info = payload.split(";").map { |el| el.split(":") }.to_h
            end
          end
          next unless job_info.present?

          next unless %w[id q t].all? { |n| job_info[n].present? }
          next unless @queues.empty? || @queues.include?(job_info["q"])

          scheduled_at = job_info["t"].to_f
          @provider.update_earliest_scheduled_at(scheduled_at)
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
        pg_conn.exec("SET application_name = #{pg_conn.escape_identifier("Exekutor::Worker::#{@worker_id}")}")
        yield pg_conn
      ensure
        ar_conn.disconnect!
      end

      def verify!(pg_conn)
        unless pg_conn.is_a?(PG::Connection)
          raise "The Active Record database must be PostgreSQL in order to use the listener"
        end
        #   TODO check connection status
      end
    end
  end
end
