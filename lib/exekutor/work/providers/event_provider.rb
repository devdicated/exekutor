# frozen_string_literal: true
module Exekutor
  module Work
    module Providers
      class EventProvider
        CHANNEL = "exekutor::job_enqueued"
        PROVIDER_CHANNEL = "exekutor::provider::%s"

        def initialize(reserver:, queues:, executor:, wait_timeout: 15, pool:)
          @uuid = SecureRandom.uuid
          @identifier = "Exekutor::Worker::#{@uuid}"
          @reserver = reserver
          @executor = executor
          @queues = queues || []
          @wait_timeout = wait_timeout
          @task = Concurrent::TimerTask.new(execution_interval: 15, &method(:run))
        end

        def start
          @task.execute
        end

        def stop
          @task.shutdown
          Exekutor::Job.connection.execute(%Q(NOTIFY "#{provider_channel}"))
        end

        private

        def provider_channel
          PROVIDER_CHANNEL % @uuid
        end

        def run(task)
          with_pg_connection do |connection|
            begin
              connection.exec(%Q(LISTEN "#{provider_channel}"))
              connection.exec(%Q(LISTEN "#{CHANNEL}"))
              catch(:shutdown) { wait_for_jobs(task, connection) }
            ensure
              connection.exec("UNLISTEN *")
            end
          end
        end

        def wait_for_jobs(task, connection)
          while task.running?
            job_info = nil
            ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
              connection.wait_for_notify(@wait_timeout) do |channel, _pid, payload|
                throw :shutdown unless task.running?
                next unless channel == CHANNEL

                job_info = payload.split(";").map { |el| el.split(":") }.to_h
              end
            end
            next unless job_info.present?

            next unless %w[id q t].all? { |n| job_info[n].present? }
            next unless @queues.empty? || @queues.include?(job_info["q"])

            scheduled_at = job_info["t"].to_f
            if scheduled_at <= Time.now.to_f
              jobs = @reserver.reserve @executor.available_threads
              jobs&.each(&@executor.method(:post))
            else
              #   TODO schedule
            end
          end
        rescue StandardError => err
          puts "Listening Biem! #{err}"
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
          pg_conn.exec("SET application_name = #{pg_conn.escape_identifier(@identifier)}")
          yield pg_conn
        ensure
          ar_conn.disconnect!
        end

        def verify!(pg_conn)
          unless pg_conn.is_a?(PG::Connection)
            raise "The Active Record database must be PostgreSQL in order to use the PostgreSQL Action Cable storage adapter"
          end
          #   TODO check connection status
        end
      end
    end
  end
end
