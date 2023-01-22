# frozen_string_literal: true
module Exekutor
  class HealthcheckServer
    include Internal::Executable, Internal::Logger
    DEFAULT_HANDLER = 'webrick'

    def initialize(worker:, pool:, port:, handler: DEFAULT_HANDLER)
      super()
      @worker = worker
      @port = port
      @pool = pool
      @handler = Rack::Handler.get(handler)
      @thread_running = Concurrent::AtomicBoolean.new false
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
      if @handler&.respond_to? :shutdown
        @handler.shutdown
      elsif @handler&.respond_to? :stop
        @handler.stop
      else
        Exekutor.say! "Cannot shutdown healthcheck server, #{@handler.class.name} does not respond to shutdown or stop"
      end
    end

    protected

    def run(worker, port)
      return unless state == :started && @thread_running.make_true
      Exekutor.say "Starting healthcheck server at 0.0.0.0:#{port}…"
      @handler.run(App.new(worker), Port: port, Host: '0.0.0.0', Silent: true,
                   Logger: ::Logger.new(File.open(File::NULL, 'w')), AccessLog: [])
    rescue StandardError => err
      Exekutor.on_fatal_error err, "[HealthServer] Runtime error!"
      if running?
        logger.info "Restarting in 10 seconds…"
        Concurrent::ScheduledTask.execute(10.0, executor: @pool, &method(:start_thread))
      end
    ensure
      @thread_running.make_false
    end

    class App

      def initialize(worker)
        @worker = worker
      end

      def call(env)
        case Rack::Request.new(env).path
        when '/'
          [200, {}, ["ID: #{@worker.id}; State: #{@worker.state}"]]
        when '/up'
          running = @worker.running?
          last_heartbeat = if running
                             @worker.last_heartbeat
                           end
          if running && (last_heartbeat.nil? || last_heartbeat < 15.minutes.ago)
            running = false
          end
          [(running ? 200 : 503), {}, ["ID: #{@worker.id}; State: #{@worker.state}; Heartbeat: #{last_heartbeat&.iso8601 || "null"}"]]
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