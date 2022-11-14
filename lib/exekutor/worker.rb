# frozen_string_literal: true
module Exekutor
  class Worker

    def self.start(config = {})
      new(config).tap { |w| w.start }
    end

    def initialize(config = {})
      @record = create_record!
      @config = config

      @reserver = Work::Reserver.new @record.id, config[:queues]
      @executor = Work::Executor.new
      @executor.after_execute do
        Concurrent::Promises.future(&method(:reserve_jobs))
      end

      @providers = []
      @providers << Work::Providers::EventProvider.new(queues: config[:queues], reserver: @reserver, executor: @executor)
      polling_interval = config.fetch(:polling_interval, 30)
      if polling_interval&.positive?
        @providers << Work::Providers::PollingProvider.new(interval: polling_interval, reserver: @reserver, executor: @executor)
      end

      @state = Concurrent::AtomicReference.new(:pending)
    end

    def start
      return false unless @state.compare_and_set(:pending, :started)

      @providers.each(&:start)
      Concurrent::Promises.schedule(0.5.seconds, &method(:reserve_jobs))
      @record.update(status: 'r')
      true
    end

    def stop
      @state.set :stopped
      @record.update(status: 's') unless @record.destroyed?

      @providers.each(&:stop)
      @executor.shutdown

      if @config[:wait_for_termination]
        if @config[:wait_for_termination].zero?
          @executor.kill
        elsif @config[:wait_for_termination].positive?
          unless @executor.wait_for_termination @config[:wait_for_termination]
            @executor.kill
          end
        else
          @executor.wait_for_termination
        end
      end

      @record.destroy
      true
    end

    def state
      @state.get
    end

    def running?
      @state.get == :started
    end

    def reserve_jobs
      jobs = @reserver.reserve @executor.available_threads
      jobs&.each(&@executor.method(:post))
    end

    private

    def create_record!
      Info::Worker.create!({
                             hostname: Socket.gethostname,
                             pid: Process.pid,
                             info: {}
                           })
    end

  end
end