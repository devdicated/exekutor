# frozen_string_literal: true
module Exekutor
  module Internal
    # Serves a simple health check app
    class HealthcheckServer
      include Internal::Logger
      include Internal::Executable

      DEFAULT_HANDLER = "webrick"

      def initialize(worker:, pool:, port:, handler: DEFAULT_HANDLER, heartbeat_timeout: 30)
        super()
        @worker = worker
        @pool = pool
        @port = port
        @handler = Rack::Handler.get(handler)
        @heartbeat_timeout = heartbeat_timeout
        @thread_running = Concurrent::AtomicBoolean.new false
        @server = Concurrent::AtomicReference.new
      end

      def start
        return false unless compare_and_set_state :pending, :started

        start_thread
      end

      def running?
        super && @thread_running.value
      end

      def stop
        set_state :stopped
        return unless @thread_running.value

        server = @server.value
        if server&.respond_to? :shutdown
          server.shutdown
        elsif server&.respond_to? :stop
          server.stop
        elsif server
          Exekutor.say! "Cannot shutdown healthcheck server, #{server.class.name} does not respond to shutdown or stop"
        end
      end

      protected

      def run(worker, port)
        return unless state == :started && @thread_running.make_true

        Exekutor.say "Starting healthcheck server at 0.0.0.0:#{port}… (Timeout: #{@heartbeat_timeout} minutes)"
        @handler.run(App.new(worker, @heartbeat_timeout), Port: port, Host: "0.0.0.0", Silent: true,
                     Logger: ::Logger.new(File.open(File::NULL, "w")), AccessLog: []) do |server|
          @server.set server
        end
      rescue StandardError => err
        Exekutor.on_fatal_error err, "[HealthServer] Runtime error!"
        if running?
          logger.info "Restarting in 10 seconds…"
          Concurrent::ScheduledTask.execute(10.0, executor: @pool, &method(:start_thread))
        end
      ensure
        @thread_running.make_false
      end

      # The Rack-app for the health-check server
      class App

        def initialize(worker, heartbeat_timeout)
          @worker = worker
          @heartbeat_timeout = heartbeat_timeout
        end

        def flatlined?
          last_heartbeat = @worker.last_heartbeat
          last_heartbeat.nil? || last_heartbeat < @heartbeat_timeout.minutes.ago
        end

        def call(env)
          case Rack::Request.new(env).path
          when "/"
            [200, {}, [
              <<~RESPONSE
                [Healthcheck]
                 - Use GET /ready to check whether the worker is running and connected to the DB
                 - Use GET /live to check whether the worker is running and is not hanging
                 - Use GET /threads to check thread usage
              RESPONSE
            ]]
          when "/ready"
            running = @worker.running?
            if running
              Exekutor::Job.connection_pool.with_connection do |connection|
                running = connection.active?
              end
            end
            running = false if running && flatlined?
            [(running ? 200 : 503), {}, [
              "#{running ? "[OK]" : "[Service unavailable]"} ID: #{@worker.id}; State: #{@worker.state}"
            ]]
          when "/live"
            running = @worker.running?
            last_heartbeat = if running
                               @worker.last_heartbeat
                             end
            if running && (last_heartbeat.nil? || last_heartbeat < @heartbeat_timeout.minutes.ago)
              running = false
            end
            [(running ? 200 : 503), {}, [
              "#{running ? "[OK]" : "[Service unavailable]"} ID: #{@worker.id}; State: #{@worker.state}; Heartbeat: #{last_heartbeat&.iso8601 || "null"}"
            ]]
          when "/threads"
            if @worker.running?
              info = @worker.thread_stats
              [(info ? 200 : 503), {}, [info.to_json]]
            else
              [503, {}, [{ error: "Worker not running" }.to_json]]
            end
          else
            [404, {}, ["Not found"]]
          end
        end
      end

      private

      def start_thread
        @pool.post(@worker, @port, &method(:run)) if state == :started
      end
    end
  end
end