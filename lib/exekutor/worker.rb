# frozen_string_literal: true

require_relative "internal/executable"

module Exekutor
  # The job worker
  class Worker
    include Internal::Executable

    # Creates a new worker with the specified config and immediately starts it
    # @see #initialize
    #
    # @return The worker
    def self.start(config = {})
      new(config).tap(&:start)
    end

    # Creates a new worker with the specified config
    # @param config [Hash] The worker configuration
    # @option config [String] :identifier the identifier for this worker
    # @option config [Array<String>] :queues the queues to work on
    # @option config [Integer] :min_threads the minimum number of execution threads that should be active
    # @option config [Integer] :max_threads the maximum number of execution threads that may be active
    # @option config [Integer] :max_thread_idletime the maximum number of seconds a thread may be idle before being stopped
    # @option config [Integer] :polling_interval the polling interval in seconds
    # @option config [Float] :poling_jitter the polling jitter
    # @option config [Boolean] :set_db_connection_name whether the DB connection name should be set
    # @option config [Integer,Boolean] :wait_for_termination how long the worker should wait on jobs to be completed before exiting
    def initialize(config = {})
      super()
      @config = config
      @record = create_record!

      @reserver = Internal::Reserver.new @record.id, config[:queues]
      @executor = Internal::Executor.new(**config.slice(:min_threads, :max_threads, :max_thread_idletime))

      provider_threads = config.fetch(:enable_listener, true) ? 2 : 1
      provider_pool = Concurrent::FixedThreadPool.new provider_threads, max_queue: provider_threads,
                                                      name: "exekutor-provider"

      @provider = Internal::Provider.new reserver: @reserver, executor: @executor, pool: provider_pool,
                                         **config.slice(:polling_interval, :polling_jitter)
                                                 .transform_keys(polling_jitter: :interval_jitter)
      listener = if config.fetch(:enable_listener, true)
                   Internal::Listener.new worker_id: @record.id, provider: @provider, pool: provider_pool,
                                          queues: config[:queues],
                                          set_db_connection_name: config[:set_db_connection_name]
                 end

      @executor.after_execute(@record) do |_job, worker_info|
        worker_info.heartbeat!
        @provider.poll if @provider.running?
      end
      @provider.on_queue_empty(@record) do |worker_info|
        worker_info.heartbeat!
        @executor.prune_pool
      end

      @executables = [@executor, @provider, listener].compact.freeze

      @callbacks = {
        queue_empty: Concurrent::Array.new
      }.freeze
    end

    # Starts the worker. Does nothing if the worker has already started.
    # @return [Boolean] whether the worker was started
    def start
      return false unless compare_and_set_state(:pending, :started)
      Internal::Hooks.run :startup, self do
        @executables.each(&:start)
        @record.update(status: "r")
      end
      true
    end

    # Stops the worker. If +wait_for_termination+ is set, this method blocks until the execution thread is terminated
    # or killed.
    # @return true
    def stop
      Internal::Hooks.run :shutdown, self do
        set_state :stopped
        @record.update(status: "s") unless @record.destroyed?

        @executables.reverse_each(&:stop)

        wait_for_termination @config[:wait_for_termination] if @config[:wait_for_termination]

        @record.destroy
        @stop_event&.set
      end
      true
    end

    # Kills the worker. Does not wait for any jobs to be completed.
    # @return true
    def kill
      Thread.new do
        @executables.reverse_each(&:stop)
        @stop_event&.set
      end
      @executor.kill
      @record.destroy
      true
    end

    # Blocks until the worker is stopped.
    def join
      @stop_event = Concurrent::Event.new
      Kernel.loop do
        @stop_event.wait 10
        break unless running?
      end
    end

    # Reserves and executes jobs.
    def reserve_jobs
      @provider.poll
    end

    # The worker ID.
    def id
      @record.id
    end

    private

    # Waits for the execution threads to finish. Does nothing if +timeout+ is falsey. If +timeout+ is zero, the
    # execution threads are killed immediately. If +timeout+ is a positive +Numeric+, waits for the indicated amount of
    # seconds to let the execution threads finish and kills the threads if the timeout is exceeded. Otherwise; waits
    # for the execution threads to finish indefinitely.
    # @param timeout The time to wait.
    def wait_for_termination(timeout)
      if timeout.is_a?(Numeric) && timeout.zero?
        @executor.kill
      elsif timeout.is_a?(Numeric) && timeout.positive?
        @executor.kill unless @executor.wait_for_termination timeout
      elsif timeout
        @executor.wait_for_termination
      end
    end

    # Creates the active record entry for this worker.
    def create_record!
      info = {}
      info.merge!(@config.slice(:identifier, :max_threads, :queues, :polling_interval))
      Info::Worker.create!({
                             hostname: Socket.gethostname,
                             pid: Process.pid,
                             info: info.compact
                           })
    end
  end
end
