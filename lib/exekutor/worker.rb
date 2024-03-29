# frozen_string_literal: true

require_relative "internal/executable"

module Exekutor
  # The job worker
  class Worker
    include Internal::Executable

    attr_reader :record

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
    # @option config [ActiveSupport::Duration] :max_thread_idletime the maximum duration a thread may be idle before
    #   being stopped
    # @option config [ActiveSupport::Duration] :polling_interval the polling interval
    # @option config [Float] :poling_jitter the polling jitter
    # @option config [Boolean] :set_db_connection_name whether the DB connection name should be set
    # @option config [Integer,Boolean] :wait_for_termination how long the worker should wait on jobs to be completed
    #   before exiting
    # @option config [Integer] :status_server_port the port to run the status server on
    # @option config [String] :status_server_handler The name of the rack handler to use for the status server
    # @option config [ActiveSupport::Duration] :healthcheck_timeout The timeout of a worker in minutes before the
    #   healthcheck server deems it as down
    def initialize(config = {})
      super()
      @config = config
      @record = create_record!

      provider_pool = create_provider_pool(config)

      @executor = create_executor(config)
      @provider = create_provider(config, @executor, provider_pool)

      @executables = [@executor, @provider]
      create_listener(provider_pool, config) if config.fetch(:enable_listener, true)
      create_status_server(provider_pool, config) if config[:status_server_port].to_i.positive?
      @executables.freeze
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
        self.state = :stopped
        unless @record.destroyed?
          begin
            @record.update(status: "s")
          rescue StandardError
            # ignored
          end
        end
        @executables.reverse_each(&:stop)
        wait_for_termination @config[:wait_for_termination]

        begin
          @record.destroy
        rescue StandardError
          # ignored
        end
        @stop_event&.set if defined?(@stop_event)
      end
      true
    end

    # Kills the worker. Does not wait for any jobs to be completed.
    # @return true
    def kill
      Thread.new do
        @executables.reverse_each(&:stop)
        @stop_event&.set if defined?(@stop_event)
      end
      @executor.kill
      begin
        @record.destroy
      rescue StandardError
        # ignored
      end
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
      @provider.poll if @provider&.running?
    end

    # The worker ID.
    def id
      @record.id
    end

    # @return [Time,nil] The timestamp of the last heartbeat. The timestamp is truncated to whole minutes.
    def last_heartbeat
      @record.last_heartbeat_at
    end

    # Returns the thread usage for this worker. The resulting hash will contain the following key-value pairs:
    # - +:minimum+, (Integer) the minimum number of threads that should be active;
    # - +:maximum+, (Integer) the maximum number of threads may should be active;
    # - +:available+, (Integer) the number of threads that are available to execute new jobs;
    # - +:usage_percent+, (Float, 0-100) the percentage of workers that are currently busy executing jobs.
    # @return [Hash] the thread usage
    def thread_stats
      available = @executor.available_threads
      usage_percent = (((100 - (available * 100.0 / @executor.maximum_threads))).round(2) if @executor.running?)
      {
        minimum: @executor.minimum_threads,
        maximum: @executor.maximum_threads,
        available: available,
        usage_percent: usage_percent
      }
    end

    private

    def create_provider_pool(config)
      provider_threads = 1
      provider_threads += 1 if config.fetch(:enable_listener, true)
      provider_threads += 1 if config[:status_server_port].to_i.positive?

      Concurrent::FixedThreadPool.new provider_threads, max_queue: provider_threads, name: "exekutor-provider"
    end

    def create_executor(worker_options)
      executor = Internal::Executor.new(**executor_options(worker_options))

      executor.after_execute(@record) do |_job, worker_info|
        begin
          worker_info.heartbeat!
        rescue StandardError
          # ignored
        end
        reserve_jobs
      end

      executor
    end

    def executor_options(worker_options)
      worker_options.slice(:min_threads, :max_threads, :max_thread_idletime,
                           :delete_completed_jobs, :delete_discarded_jobs,
                           :delete_failed_jobs)
    end

    def create_provider(worker_options, executor, thread_pool)
      @reserver = Internal::Reserver.new @record.id, **worker_options.slice(:queues, :min_priority, :max_priority)
      provider = Internal::Provider.new reserver: @reserver, executor: executor, pool: thread_pool,
                                        **provider_options(worker_options)

      provider.on_queue_empty(@record, executor) do |worker_info, thr_executor|
        begin
          worker_info.heartbeat!
        rescue StandardError
          # ignored
        end
        thr_executor.prune_pool
      end

      provider
    end

    def provider_options(worker_options)
      worker_options.slice(:polling_interval, :polling_jitter).transform_keys do |key|
        case key
        when :polling_jitter
          :interval_jitter
        else
          key
        end
      end
    end

    def create_listener(provider_pool, config)
      listener = Internal::Listener.new worker_id: @record.id, provider: @provider, pool: provider_pool,
                                        **listener_options(config)
      @executables << listener
    end

    def listener_options(worker_options)
      worker_options.slice(:queues, :set_db_connection_name)
    end

    def create_status_server(provider_pool, config)
      server = Internal::StatusServer.new worker: self, pool: provider_pool, **status_server_options(config)
      @executables << server
    end

    def status_server_options(worker_options)
      worker_options.slice(:status_server_port, :status_server_handler, :healthcheck_timeout).transform_keys do |key|
        case key
        when :healthcheck_timeout
          :heartbeat_timeout
        else
          key.to_s.gsub(/^status_server_/, "").to_sym
        end
      end
    end

    # Waits for the execution threads to finish. Does nothing if +timeout+ is falsey. If +timeout+ is zero, the
    # execution threads are killed immediately. If +timeout+ is a positive +Numeric+, waits for the indicated amount of
    # seconds to let the execution threads finish and kills the threads if the timeout is exceeded. Otherwise; waits
    # for the execution threads to finish indefinitely.
    # @param timeout The time to wait.
    def wait_for_termination(timeout)
      if timeout.is_a?(Numeric) && timeout.zero?
        @executor.kill
      elsif timeout.is_a?(Numeric) && timeout.positive?
        @executor.kill unless @executor.wait_for_termination(timeout)
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
