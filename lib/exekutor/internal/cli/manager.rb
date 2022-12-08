require_relative "default_option_value"
require_relative "daemon"

module Exekutor
  # @private
  module Internal
    module CLI
      # Manager for the CLI
      # @private
      class Manager

        def initialize(options)
          @global_options = options
        end

        # Starts a new worker
        # @option options [Boolean] :restart Whether the worker is being restarted
        # @option options [Boolean] :daemonize Whether the worker should be daemonized
        # @option options [String] :environment The Rails environment to load
        # @option options [String] :queue The queue(s) to watch
        # @option options [Integer] :max_threads The maximum number of threads to use for job execution
        # @option options [Integer] :poll_interval The interval in seconds for job polling
        # @return [Void]
        def start(options)
          daemonize(restarting: options[:restart]) if options[:daemonize]

          load_application(options[:environment])

          # TODO do we want to use Exekutor#config here or use it as fallback in the worker?
          configuration = Exekutor.config.worker_options
                                  .reverse_merge(set_connection_application_name: true)
                                  .merge(@global_options.slice(:identifier, :verbose, :quiet))
                                  .merge(options.slice(:queue, :max_threads, :poll_interval)
                                                .reject { |_, value| value.is_a? DefaultOptionValue })

          configuration[:queue] = nil if configuration[:queue] == ["*"]

          # TODO health check server

          # Specify `yield: true` to prevent running in the context of the loaded module
          ActiveSupport.on_load(:exekutor, yield: true) do
            ActiveSupport.on_load(:active_record, yield: true) do
              worker = Worker.new(configuration)
              %w[INT TERM QUIT].each do |signal|
                ::Kernel.trap(signal) { ::Thread.new { worker.stop } }
              end

              Process.setproctitle "Exekutor worker #{worker.id} [#{Rails.root}]"
              if configuration[:set_connection_application_name]
                Exekutor::BaseRecord.connection.class.set_callback(:checkout, :after) do
                  Internal::Connection.set_application_name raw_connection, worker.id
                end
                Exekutor::BaseRecord.connection_pool.connections.each do |conn|
                  Internal::Connection.set_application_name conn.raw_connection, worker.id
                end
              end

              ActiveSupport.on_load(:active_job, yield: true) do
                puts "Worker #{worker.id} started (Use `#{Rainbow("ctrl + c").indianred}` to stop)" unless quiet?
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
              stop_options = if @global_options[:pidfile].present? && @global_options[:pidfile] != DEFAULT_PIDFILE
                               "--pid #{pidfile} "
                             elsif identifier
                               "--id #{identifier} "
                             end

              puts "Running worker as a daemon… (Use `#{Rainbow("exekutor #{stop_options}stop").indianred}` to stop)"
            end
          end
          daemonizer.daemonize
        rescue Daemon::Error => e
          puts Rainbow(e.message).red
          raise GLI::CustomExit.new(nil, 1)
        end

        def load_application(environment, path = "config/environment.rb")
          ENV["RAILS_ENV"] = environment unless environment.nil?
          require File.expand_path(path)
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

        DEFAULT_PIDFILE = DefaultPidFileValue.new.freeze

        DEFAULT_MAX_THREADS = DefaultOptionValue.new("Active record pool size minus 1, with a minimum of 1").freeze
        DEFAULT_QUEUE = DefaultOptionValue.new("All queues").freeze
        DEFAULT_FOREVER = DefaultOptionValue.new("Forever").freeze

        class Error < StandardError; end
      end
    end
  end
end