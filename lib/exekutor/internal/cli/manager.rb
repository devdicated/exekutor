require_relative "application_loader"
require_relative "default_option_value"
require_relative "daemon"

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
          daemonize(restarting: options[:restart]) if options[:daemonize]

          load_application(options[:environment])

          config_files = if options[:configfile].is_a? DefaultConfigFileValue
                           options[:configfile].to_a(@global_options[:identifier])
                         else
                           options[:configfile]&.map { |path| File.expand_path(path, Rails.root) }
                         end

          worker_options = DEFAULT_CONFIGURATION.dup

          config_files&.each do |path|
            puts "Loading config file: #{path}" if verbose?
            config = begin
                       YAML.safe_load(File.read(path), symbolize_names: true)
                     rescue => e
                       raise Error, "Cannot read config file: #{path} (#{e.to_s})"
                     end
            unless config.keys == [:exekutor]
              raise Error, "Config should have an `exekutor` root node: #{path} (Found: #{config.keys.join(', ')})"
            end

            # Remove worker specific options before calling Exekutor.config.set
            worker_options.merge! config[:exekutor].extract!(:queue, :healthcheck_port)

            begin
              Exekutor.config.set **config[:exekutor]
            rescue => e
              raise Error, "Cannot load config file: #{path} (#{e.to_s})"
            end
          end

          worker_options.merge! Exekutor.config.worker_options
          worker_options.merge! @global_options.slice(:identifier)
          if verbose?
            worker_options[:verbose] = true
          elsif quiet?
            worker_options[:quiet] = true
          end
          if options[:threads] && !options[:threads].is_a?(DefaultOptionValue)
            min, max = if options[:threads].is_a?(Integer)
                         [options[:threads], options[:threads]]
                       else
                         options[:threads].to_s.split(":")
                       end
            if max.nil?
              options[:min_threads] = options[:max_threads] = Integer(min)
            else
              options[:min_threads] = Integer(min)
              options[:max_threads] = Integer(max)
            end
          end
          worker_options.merge!(
            options.slice(:queue, :min_threads, :max_threads, :poll_interval)
                   .reject { |_, value| value.is_a? DefaultOptionValue }
                   .transform_keys(poll_interval: :polling_interval)
          )

          worker_options[:queue] = nil if worker_options[:queue] == ["*"]

          # TODO health check server

          # Specify `yield: true` to prevent running in the context of the loaded module
          ActiveSupport.on_load(:exekutor, yield: true) do
            ActiveSupport.on_load(:active_record, yield: true) do
              worker = Worker.new(worker_options)
              %w[INT TERM QUIT].each do |signal|
                ::Kernel.trap(signal) { ::Thread.new { worker.stop } }
              end

              Process.setproctitle "Exekutor worker #{worker.id} [#{Rails.root}]"
              if worker_options[:set_db_connection_name]
                Internal::BaseRecord.connection.class.set_callback(:checkout, :after) do
                  Internal::DatabaseConnection.set_application_name raw_connection, worker.id
                end
                Internal::BaseRecord.connection_pool.connections.each do |conn|
                  Internal::DatabaseConnection.set_application_name conn.raw_connection, worker.id
                end
              end

              ActiveSupport.on_load(:active_job, yield: true) do
                puts "Worker #{worker.id} started (Use `#{Rainbow("ctrl + c").magenta}` to stop)" unless quiet?
                puts "#{worker_options.pretty_inspect}" if verbose?
                begin
                  worker.start
                  worker.join
                ensure
                  worker.stop if worker.running?
                end
              end
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
          sleep(0.3)
          wait_until = if options[:shutdown_timeout].nil? || options[:shutdown_timeout] == DEFAULT_FOREVER
                         nil
                       else
                         Time.now + options[:shutdown_timeout]
                       end
          while daemon.status?(:running, :not_owned)
            puts "Waiting for worker to finish…" unless quiet?
            if wait_until && wait_until > Time.now
              Process.kill("TERM", pid)
              break
            end
            sleep 0.1
          end
          puts "Worker (PID: #{pid}) stopped." unless quiet?
        end

        def restart(stop_options, start_options)
          stop stop_options.merge(restart: true)
          start start_options.merge(restart: true, daemonize: true)
        end

        private

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

        # Daemonizes the current process. Do this before loading your application to prevent deadlocks.
        # @return [Void]
        def daemonize(restarting: false)
          daemonizer = Daemon.new(pidfile: pidfile)
          daemonizer.validate!
          unless quiet?
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
          daemonizer.daemonize
        rescue Daemon::Error => e
          puts Rainbow(e.message).red
          raise GLI::CustomExit.new(nil, 1)
        end

        class DefaultPidFileValue < DefaultOptionValue
          def initialize
            super("tmp/pids/exekutor[.%{identifier}].pid")
          end

          def for_identifier(identifier)
            if identifier.nil? || identifier.length.zero?
              "tmp/pids/exekutor.pid"
            else
              "tmp/pids/exekutor.#{identifier}.pid"
            end
          end
        end

        class DefaultConfigFileValue < DefaultOptionValue
          def initialize
            super('"config/exekutor.yml", overridden by "config/exekutor.%{identifier}.yml" if an identifier is specified')
          end

          def to_a(identifier = nil)
            files = []
            files << %w[config/exekutor.yml config/exekutor.yaml]
                       .lazy.map { |path| Rails.root.join(path) }
                       .find { |path| File.exists? path }
            if identifier.present?
              files << %W[config/exekutor.#{identifier}.yml config/exekutor.#{identifier}.yaml]
                         .lazy.map { |path| Rails.root.join(path) }
                         .find { |path| File.exists? path }
            end
            files.compact
          end
        end

        DEFAULT_PIDFILE = DefaultPidFileValue.new.freeze
        DEFAULT_CONFIG_FILES = DefaultConfigFileValue.new.freeze

        DEFAULT_THREADS = DefaultOptionValue.new("Minimum: 1, Maximum: Active record pool size minus 1, with a minimum of 1").freeze
        DEFAULT_QUEUE = DefaultOptionValue.new("All queues").freeze
        DEFAULT_FOREVER = DefaultOptionValue.new("Forever").freeze

        DEFAULT_CONFIGURATION = { set_db_connection_name: true }

        class Error < StandardError; end
      end
    end
  end
end