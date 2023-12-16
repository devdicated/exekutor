# frozen_string_literal: true

module Exekutor
  module Internal
    # Serves a simple health check app. The app provides 4 endpoints:
    # - +/+, which lists the other endpoints;
    # - +/ready+, which indicates whether the worker is ready to start work;
    # - +/live+, which indicates whether the worker is ready and whether the worker is still alive;
    # - +/threads+, which indicated the thread usage of the worker.
    #
    # Please note that this server uses +webrick+ by default, which is no longer a default gem from ruby 3.0 onwards.
    #
    # === Example requests
    #    $ curl localhost:9000/ready
    #    [OK] ID: f1a2ee6a-cdac-459c-a4b8-de7c6a8bbae6; State: started
    #    $ curl localhost:9000/live
    #    [OK] ID: f1a2ee6a-cdac-459c-a4b8-de7c6a8bbae6; State: started; Heartbeat: 2023-04-05T16:27:00Z
    #    $ curl localhost:9000/threads
    #    {"minimum":1,"maximum":10,"available":4,"usage_percent":60.0}
    class StatusServer
      include Internal::Logger
      include Internal::Executable

      DEFAULT_HANDLER = "webrick"

      def initialize(worker:, pool:, port:, handler: DEFAULT_HANDLER, heartbeat_timeout: 30.minutes)
        super()
        @worker = worker
        @pool = pool
        @port = port
        @handler = Rack::Handler.get(handler)
        @heartbeat_timeout = heartbeat_timeout
        @thread_running = Concurrent::AtomicBoolean.new false
        @server = Concurrent::AtomicReference.new
      end

      # Starts the web server
      def start
        return false unless compare_and_set_state :pending, :started

        start_thread
      end

      # @return [Boolean] whether the web server is active
      def running?
        super && @thread_running.value
      end

      # Stops the web server
      def stop
        self.state = :stopped
        return unless @thread_running.value

        server = @server.value
        shutdown_method = %i[shutdown stop].find { |method| server.respond_to? method }
        if shutdown_method
          server.send(shutdown_method)
          Exekutor.say "Status server stopped"
        elsif server
          Exekutor.print_error "Cannot shutdown status server, " \
                               "#{server.class.name} does not respond to `shutdown` or `stop`"
        end
      end

      protected

      # Runs the web server, should be called from a separate thread
      def run(worker, port)
        return unless state == :started && @thread_running.make_true

        Exekutor.say "Starting status server at 0.0.0.0:#{port}… (Timeout: #{@heartbeat_timeout.inspect})"
        @handler.run(App.new(worker, @heartbeat_timeout), Port: port, Host: "0.0.0.0", Silent: true,
                     Logger: ::Logger.new(File.open(File::NULL, "w")), AccessLog: []) do |server|
          @server.set server
        end
      rescue StandardError => e
        Exekutor.on_fatal_error e, "[Status server] Runtime error!"
        if running?
          logger.info "Restarting in 10 seconds…"
          Concurrent::ScheduledTask.execute(10.0, executor: @pool) { start_thread }
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

        def call(env)
          case Rack::Request.new(env).path
          when "/"
            render_root
          when "/ready"
            render_ready
          when "/live"
            render_live
          when "/threads"
            render_threads
          else
            [404, {}, ["Not found"]]
          end
        end

        private

        def flatlined?(last_heartbeat = @worker.last_heartbeat)
          last_heartbeat.nil? || last_heartbeat < @heartbeat_timeout.ago
        end

        def render_threads
          if @worker.running?
            info = @worker.thread_stats
            [(info ? 200 : 503), { "Content-Type" => "application/json" }, [info.to_json]]
          else
            [503, { "Content-Type" => "application/json" }, [{ error: "Worker not running" }.to_json]]
          end
        end

        def render_live
          running = @worker.running?
          last_heartbeat = (@worker.last_heartbeat if running)
          running = false if flatlined?(last_heartbeat)
          [(running ? 200 : 503), { "Content-Type" => "text/plain" }, [
            "#{running ? "[OK]" : "[Service unavailable]"} ID: #{@worker.id}; State: #{@worker.state}; " \
            "Heartbeat: #{last_heartbeat&.iso8601 || "null"}"
          ]]
        end

        def render_ready
          running = @worker.running?
          if running
            Exekutor::Job.connection_pool.with_connection do |connection|
              running = connection.active?
            end
          end
          running = false if running && flatlined?
          [(running ? 200 : 503), { "Content-Type" => "text/plain" }, [
            "#{running ? "[OK]" : "[Service unavailable]"} ID: #{@worker.id}; State: #{@worker.state}"
          ]]
        end

        def render_root
          [200, {}, [
            <<~RESPONSE
              [Exekutor]
               - Use GET /ready to check whether the worker is running and connected to the DB
               - Use GET /live to check whether the worker is running and is not hanging
               - Use GET /threads to check thread usage
            RESPONSE
          ]]
        end
      end

      private

      def start_thread
        @pool.post(@worker, @port) { |*args| run(*args) } if state == :started
      end
    end
  end
end
