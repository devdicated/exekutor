# frozen_string_literal: true
module Exekutor
  class Worker
    include Executable

    def self.start(config = {})
      new(config).tap { |w| w.start }
    end

    def initialize(config = {})
      super()
      @record = create_record!
      @config = config

      @reserver = Jobs::Reserver.new @record.id, config[:queues]
      @executor = Jobs::Executor.new config

      provider_pool = Concurrent::FixedThreadPool.new 2, name: "exekutor-provider", max_queue: 2
      @provider = Jobs::Provider.new reserver: @reserver, executor: @executor, pool: provider_pool,
                                     polling_interval: config[:polling_interval] || 60
      listener = Jobs::Listener.new worker_id: @record.id, queues: config[:queues], provider: @provider,
                                    pool: provider_pool

      @executor.after_execute(@record) do |_job, worker_info|
        worker_info.heartbeat!
        @provider.poll
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