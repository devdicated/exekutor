# frozen_string_literal: true

require_relative "application_loader"
require_relative "default_option_value"
require_relative "daemon"

# rubocop:disable Style/FormatStringToken
module Exekutor
  # @private
  module Internal
    module CLI
      # Manager for the CLI
      # @private
      class Manager
        include ApplicationLoader

        def initialize(options)
          @global_options = options
        end

        # Starts a new worker
        # @option options [Boolean] :restart Whether the worker is being restarted
        # @option options [Boolean] :daemonize Whether the worker should be daemonized
        # @option options [String] :environment The Rails environment to load
        # @option options [String] :queue The queue(s) to watch
        # @option options [String] :threads The number of threads to use for job execution
        # @option options [Integer] :poll_interval The interval in seconds for job polling
        # @return [Void]

        def start(options)
          Process.setproctitle "Exekutor worker (Initializing…) [#{$PROGRAM_NAME}]"
          daemonize(restarting: options[:restart]) if options[:daemonize]

          load_application(options[:environment])

          # Specify `yield: true` to prevent running in the context of the loaded module
          ActiveSupport.on_load(:exekutor, yield: true) do
            worker_options = worker_options(options[:configfile], cli_worker_overrides(options))

            ActiveSupport.on_load(:active_record, yield: true) do
              start_and_join_worker(worker_options, options[:daemonize])
            end
          end
        end

        def stop(options)
          daemon = Daemon.new(pidfile: pidfile)
          pid = daemon.pid
          if pid.nil?
            unless quiet?
              if options[:restart]
                puts "Executor was not running"
              else
                puts "Executor is not running (pidfile not found at #{daemon.pidfile})"
              end
            end
            return
          elsif daemon.status? :not_running, :dead
            return
          end

          Process.kill("INT", pid)
          wait_for_process_end(daemon, pid, shutdown_timeout(options))
          puts "Worker (PID: #{pid}) stopped." unless quiet?
        end

        def restart(stop_options, start_options)
          stop stop_options.merge(restart: true)
          start start_options.merge(restart: true, daemonize: true)
        end

        private

        def worker_options(config_file, cli_overrides)
          worker_options = DEFAULT_CONFIGURATION.dup

          load_config_files(config_file, worker_options)

          worker_options.merge! Exekutor.config.worker_options
          worker_options.merge! @global_options.slice(:identifier)
          worker_options.merge! cli_overrides

          if quiet?
            worker_options[:quiet] = true
          elsif verbose?
            worker_options[:verbose] = true
          end

          worker_options[:queue] = nil if Array.wrap(worker_options[:queue]) == ["*"]
          worker_options
        end

        def cli_worker_overrides(cli_options)
          worker_options = cli_options.slice(:queue, :poll_interval)
                                      .reject { |_, value| value.is_a? DefaultOptionValue }
                                      .transform_keys(poll_interval: :polling_interval)

          min_threads, max_threads = parse_thread_limitations(cli_options[:threads])
          if min_threads
            worker_options[:min_threads] = min_threads
            worker_options[:max_threads] = max_threads || min_threads
          end

          worker_options
        end

        def parse_thread_limitations(threads)
          return if threads.blank? || threads.is_a?(DefaultOptionValue)

          if threads.is_a?(Integer)
            [threads, threads]
          else
            threads.to_s.split(":").map { |s| Integer(s) }
          end
        end

        def load_config_files(config_files, worker_options)
          config_files = if config_files.is_a? DefaultConfigFileValue
                           config_files.to_a(@global_options[:identifier])
                         else
                           config_files&.map { |path| File.expand_path(path, Rails.root) }
                         end

          config_files&.each { |path| load_config_file(path, worker_options) }
        end

        def load_config_file(path, worker_options)
          puts "Loading config file: #{path}" if verbose?
          config = begin
                     YAML.safe_load(File.read(path), symbolize_names: true)
                   rescue StandardError => e
                     raise Error, "Cannot read config file: #{path} (#{e})"
                   end
          unless config.keys == [:exekutor]
            raise Error, "Config should have an `exekutor` root node: #{path} (Found: #{config.keys.join(", ")})"
          end

          # Remove worker specific options before calling Exekutor.config.set
          worker_options.merge! config[:exekutor].extract!(:queue, :status_server_port)

          begin
            Exekutor.config.set(**config[:exekutor])
          rescue StandardError => e
            raise Error, "Cannot load config file: #{path} (#{e})"
          end
        end

        def start_and_join_worker(worker_options, is_daemonized)
          worker = Worker.new(worker_options)
          %w[INT TERM QUIT].each do |signal|
            ::Kernel.trap(signal) { ::Thread.new { worker.stop } }
          end

          Process.setproctitle "Exekutor worker #{worker.id} [#{Rails.root}]"
          set_db_connection_name(worker.id) if worker_options[:set_db_connection_name]

          ActiveSupport.on_load(:active_job, yield: true) do
            worker.start
            print_startup_message(worker, worker_options) unless quiet? || is_daemonized
            worker.join
          ensure
            worker.stop if worker.running?
          end
        end

        def print_startup_message(worker, worker_options)
          puts "Worker #{worker.id} started (Use `#{Rainbow("ctrl + c").magenta}` to stop)"
          puts worker_options.pretty_inspect if verbose?
        end

        # rubocop:disable Naming/AccessorMethodName
        def set_db_connection_name(worker_id)
          # rubocop:enable Naming/AccessorMethodName
          Internal::BaseRecord.connection.class.set_callback(:checkout, :after) do
            Internal::DatabaseConnection.set_application_name raw_connection, worker_id
          end
          Internal::BaseRecord.connection_pool.connections.each do |conn|
            Internal::DatabaseConnection.set_application_name conn.raw_connection, worker_id
          end
        end

        def wait_for_process_end(daemon, pid, shutdown_timeout)
          wait_until = (Time.now.to_f + shutdown_timeout if shutdown_timeout)
          sleep 0.1
          while daemon.status?(:running, :not_owned)
            if wait_until && wait_until > Time.now.to_f
              puts "Sending TERM signal" unless quiet?
              Process.kill("TERM", pid) if pid
              break
            end
            sleep 0.1
          end
        end

        def shutdown_timeout(options)
          if options[:shutdown_timeout].nil? || options[:shutdown_timeout] == DEFAULT_FOREVER
            nil
          else
            options[:shutdown_timeout]
          end
        end

        # @return [Boolean] Whether quiet mode is enabled. Overrides verbose mode.
        def quiet?
          !!@global_options[:quiet]
        end

        # @return [Boolean] Whether verbose mode is enabled. Always returns false if quiet mode is enabled.
        def verbose?
          !quiet? && !!@global_options[:verbose]
        end

        # @return [String] The identifier for this worker
        def identifier
          @global_options[:identifier]
        end

        # @return [String] The path to the pidfile
        def pidfile
          pidfile = @global_options[:pidfile] || DEFAULT_PIDFILE
          if pidfile == DEFAULT_PIDFILE
            pidfile.for_identifier(identifier)
          elsif identifier && pidfile.include?("%{identifier}")
            pidfile.sub "%{identifier}", identifier
          else
            pidfile
          end
        end

        # Daemonizes the current process.
        # @return [Void]
        def daemonize(restarting: false)
          daemonizer = Daemon.new(pidfile: pidfile)
          daemonizer.validate!
          print_daemonize_message(restarting) unless quiet?

          daemonizer.daemonize
        rescue Daemon::Error => e
          puts Rainbow(e.message).red
          raise GLI::CustomExit.new(nil, 1)
        end

        def print_daemonize_message(restarting)
          if restarting
            puts "Restarting worker as a daemon…"
          else
            stop_options = if @global_options[:pidfile] && @global_options[:pidfile] != DEFAULT_PIDFILE
                             "--pid #{pidfile} "
                           elsif identifier
                             "--id #{identifier} "
                           end

            puts "Running worker as a daemon… (Use `#{Rainbow("exekutor #{stop_options}stop").magenta}` to stop)"
          end
        end

        # The default value for the pid file
        class DefaultPidFileValue < DefaultOptionValue
          def initialize
            super("tmp/pids/exekutor[.%{identifier}].pid")
          end

          def for_identifier(identifier)
            if identifier.nil? || identifier.empty? # rubocop:disable Rails/Blank – Rails is not loaded here
              "tmp/pids/exekutor.pid"
            else
              "tmp/pids/exekutor.#{identifier}.pid"
            end
          end
        end

        # The default value for the config file
        class DefaultConfigFileValue < DefaultOptionValue
          def initialize
            super <<~DESC
              "config/exekutor.yml", overridden by "config/exekutor.%{identifier}.yml" if an identifier is specified
            DESC
          end

          def to_a(identifier = nil)
            files = []
            %w[config/exekutor.yml config/exekutor.yaml].each do |path|
              path = Rails.root.join(path)
              if File.exist? path
                files.append path
                break
              end
            end
            if identifier.present?
              %W[config/exekutor.#{identifier}.yml config/exekutor.#{identifier}.yaml].each do |path|
                path = Rails.root.join(path)
                if File.exist? path
                  files.append path
                  break
                end
              end
            end
            files
          end
        end

        DEFAULT_PIDFILE = DefaultPidFileValue.new.freeze
        DEFAULT_CONFIG_FILES = DefaultConfigFileValue.new.freeze

        DEFAULT_THREADS = DefaultOptionValue.new(
          "Minimum: 1, Maximum: Active record pool size minus 1, with a minimum of 1"
        ).freeze
        DEFAULT_QUEUE = DefaultOptionValue.new("All queues").freeze
        DEFAULT_FOREVER = DefaultOptionValue.new("Forever").freeze

        DEFAULT_CONFIGURATION = { set_db_connection_name: true }.freeze

        class Error < StandardError; end
      end
    end
  end
end
# rubocop:enable Style/FormatStringToken
