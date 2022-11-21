module Exekutor
  # The command line interface for the worker
  class CLI < Thor

    DEFAULT_PIDFILE = "tmp/pids/exekutor.pid"
    DEFAULT_DESCRIPTOR_PIDFILE = "tmp/pids/exekutor.%{identifier}.pid"

    def self.exit_on_failure?
      true
    end

    class_option :shutdown_timeout,
                 type: :numeric,
                 desc: "Number of seconds to wait for jobs to finish when shutting down before stopping the thread. (env var: GOOD_JOB_SHUTDOWN_TIMEOUT, default: -1 (forever))"
    class_option :identifier,
                 type: :string,
                 default: nil,
                 desc: "Descriptor of the worker instance, is used in the pid file and shown in the worker info"
    class_option :pidfile,
                 type: :string,
                 aliases: %i[pid],
                 desc: "Path to write daemonized Process ID (env var: GOOD_JOB_PIDFILE, default: #{DEFAULT_PIDFILE})"

    # @!macro thor.desc
    #   @!method $1
    #   @return [void]
    #   The +$1+ command. $2
    desc :start, "Starts a worker"
    long_desc <<~TEXT

    TEXT
    method_option :environment,
                  type: :string,
                  aliases: %i[env],
                  desc: "The rails environment. (env var: RAILS_ENV, default: development)"
    method_option :queue,
                  type: :string,
                  aliases: %i[q],
                  repeatable: true,
                  desc: "Queues or queue pools to work from. (env var: GOOD_JOB_QUEUES, default: *)"
    method_option :max_threads,
                  type: :numeric,
                  aliases: %i[t],
                  desc: "Default number of threads per pool to use for working jobs. (env var: GOOD_JOB_MAX_THREADS, default: 5)"
    method_option :poll_interval,
                  type: :numeric,
                  aliases: %i[p],
                  desc: "Interval between polls for available jobs in seconds (env var: GOOD_JOB_POLL_INTERVAL, default: 60)"
    method_option :daemonize,
                  type: :boolean,
                  aliases: %i[d],
                  default: false,
                  desc: "Run as a background daemon (default: false)"

    def start
      load_application!(options[:environment])
      configuration = Exekutor.config.worker_options
                              .merge(options.without(:environment, :deamonize, :pidfile, :identifier))

      # TODO Daemon.new(pidfile: configuration.pidfile).daemonize if configuration.daemonize?
      # TODO health check server

      worker = Worker.new(configuration)
      %w[INT TERM QUIT].each do |signal|
        trap(signal) { Thread.new { worker.stop } }
      end

      worker.start
      begin
        worker.join
      rescue StandardError => e
        Exekutor.print_error e
      ensure
        worker.stop if worker.running?
      end
    end

    default_task :start

    # @!macro thor.desc
    #   @!method $1
    #   @return [void]
    #   The +$1+ command. $2
    desc :stop, "Stops a daemonized worker"
    long_desc <<~TEXT

    TEXT

    def stop
      stop!
    end

    # @!macro thor.desc
    #   @!method $1
    #   @return [void]
    #   The +$1+ command. $2
    desc :start, "Restarts a daemonized worker"
    long_desc <<~TEXT

    TEXT
    method_option :environment,
                  type: :string,
                  aliases: %i[env],
                  desc: "The rails environment. (env var: RAILS_ENV, default: development)"
    method_option :queue,
                  type: :string,
                  aliases: %i[q],
                  repeatable: true,
                  desc: "Queues or queue pools to work from. (env var: GOOD_JOB_QUEUES, default: *)"
    method_option :max_threads,
                  type: :numeric,
                  aliases: %i[t],
                  desc: "Default number of threads per pool to use for working jobs. (env var: GOOD_JOB_MAX_THREADS, default: 5)"
    method_option :poll_interval,
                  type: :numeric,
                  aliases: %i[p],
                  desc: "Interval between polls for available jobs in seconds (env var: GOOD_JOB_POLL_INTERVAL, default: 60)"

    def restart
      stop!(quiet: true)
      sleep(1)
      start
    end

    no_commands do
      def stop!(quiet: false, wait_timeout: nil)
        pidfile = options[:pidfile]
        if options[:identifier]
          pidfile ||= DEFAULT_DESCRIPTOR_PIDFILE
          pidfile = pidfile.sub "%{identifier}", options[:identifier] if pidfile.include?("%{identifier}")
        else
          pidfile ||= DEFAULT_PIDFILE
        end
        unless File.exist? pidfile
          puts "Executor is not running (pidfile not found at #{pidfile})" unless quiet
          return
        end

        pid = File.read pidfile
        unless pid.to_i.positive?
          puts "Illegal PID file ('#{pid.truncate 100}' is not a pid)" unless quiet
          return
        end

        Process.kill("INT", pid.to_i)
        sleep(0.3)
        wait_until = wait_timeout.nil? ? nil : Time.now + wait_timeout
        while process_alive?(pid.to_i)
          if wait_until && wait_until > Time.now
            Process.kill("TERM", pid.to_i)
            break
          end
          sleep 0.1
        end
      end

      private

      def process_alive?(pid)
        # If sig is 0, then no signal is sent, but error checking is still performed; this can be used to check for the
        # existence of a process ID or process group ID.
        !!Process.kill(0, pid)
      rescue StandardError
        false
      end

      def load_application!(environment)
        ENV["RAILS_ENV"] = environment unless environment.nil?
        require File.expand_path("config/environment.rb")
      end
    end
  end
end
