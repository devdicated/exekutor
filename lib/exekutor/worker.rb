# frozen_string_literal: true

require_relative "internal/executable"

module Exekutor
  # The job worker
  class Worker
    include Internal::Executable

    # Creates a new worker with the specified config and immediately starts it
    # @param config [Hash] The worker configuration
    # @option config [Array<String>] :queues The queues to work on
    # TODO …
    # @return The worker
    def self.start(config = {})
      new(config).tap(&:start)
    end

    def initialize(config = {})
      super()
      @config = config
      @record = create_record!

      @reserver = Internal::Reserver.new @record.id, config[:queues]
      @executor = Internal::Executor.new config

      provider_pool = Concurrent::FixedThreadPool.new 2, name: "exekutor-provider", max_queue: 2
      @provider = Internal::Provider.new reserver: @reserver, executor: @executor, pool: provider_pool,
                                     polling_interval: config[:polling_interval] || 60
      listener = Internal::Listener.new worker_id: @record.id, provider: @provider, pool: provider_pool,
                                    queues: config[:queues],
                                    set_connection_application_name: config[:set_connection_application_name]

      @executor.after_execute(@record) do |_job, worker_info|
        worker_info.heartbeat!
        @provider.poll if @provider.running?
      end

      @executables = [@executor, @provider, listener]
    end

    def start
      return false unless compare_and_set_state(:pending, :started)

      @executables.each(&:start)
      @record.update(status: "r")
      true
    end

    def stop
      set_state :stopped
      @record.update(status: "s") unless @record.destroyed?

      @executables.reverse_each(&:stop)

      if @config[:wait_for_termination]
        if @config[:wait_for_termination].zero?
          @executor.kill
        elsif @config[:wait_for_termination].positive?
          @executor.kill unless @executor.wait_for_termination @config[:wait_for_termination]
        else
          @executor.wait_for_termination
        end
      end

      @record.destroy
      @stop_event&.set
      true
    end

    def kill
      Thread.new do
        @executables.reverse_each(&:stop)
        @stop_event&.set
      end
      @executor.kill
      @record.destroy
      true
    end

    def join
      @stop_event = Concurrent::Event.new
      Kernel.loop do
        @stop_event.wait 10
        break unless running?
      end
    end

    def reserve_jobs
      @provider.poll
    end

    def id
      @record.id
    end

    private

    def create_record!
      info = {}
      info.merge!(@config.slice(:identifier, :max_threads, :queues, :poll_interval))
      puts "config: #{@config.inspect}, info: #{info.inspect}"
      Info::Worker.create!({
                             hostname: Socket.gethostname,
                             pid: Process.pid,
                             info: info.compact
                           })
    end
  end
end