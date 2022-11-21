require_relative 'daemon'

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
                  aliases: %w[-env],
                  desc: "The rails environment. (env var: RAILS_ENV, default: development)"
    method_option :queue,
                  type: :string,
                  aliases: %w[-q],
                  repeatable: true,
                  desc: "Queues or queue pools to work from. (env var: GOOD_JOB_QUEUES, default: *)"
    method_option :max_threads,
                  type: :numeric,
                  aliases: %w[-t],
                  desc: "Default number of threads per pool to use for working jobs. (env var: GOOD_JOB_MAX_THREADS, default: 5)"
    method_option :poll_interval,
                  type: :numeric,
                  aliases: %w[-p],
                  desc: "Interval between polls for available jobs in seconds (env var: GOOD_JOB_POLL_INTERVAL, default: 60)"
    method_option :daemonize,
                  type: :boolean,
                  aliases: %w[-d],
                  default: false,
                  desc: "Run as a background daemon (default: false)"
    method_option :verbose,
                  type: :boolean,
                  aliases: %w[-v],
                  default: false,
                  desc: "Enable more output (default: false)"

    def start
      load_application!(options[:environment])
      configuration = Exekutor.config.worker_options
                              .merge(options.without(:environment, :deamonize, :pidfile, :identifier))

      Daemon.new(pidfile: pidfile(configuration)).daemonize if options.daemonize?
      # TODO health check server

      worker = Worker.new(configuration)
      %w[INT TERM QUIT].each do |signal|
        trap(signal) { Thread.new { worker.stop } }
      end

      worker.start
      Exekutor.say! "Worker running at #{::Process.pid}" if options.daemonize?
      begin
        worker.join
      ensure
        worker.stop if worker.running?
      end
    rescue StandardError => e
      Exekutor.print_error e
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
        daemon = Daemon.new(pidfile: pidfile(options))
        pid = daemon.pid
        if pid.nil?
          puts "Executor is not running (pidfile not found at #{daemon.pidfile})" unless quiet
          return
        elsif daemon.status? :not_running, :dead
          return
        end

        Process.kill("INT", pid)
        sleep(0.3)
        wait_until = wait_timeout.nil? ? nil : Time.now + wait_timeout
        while daemon.status?(:running, :not_owned)
          if wait_until && wait_until > Time.now
            Process.kill("TERM", pid)
            break
          end
          sleep 0.1
        end
      end

      def pidfile(options)
        pidfile = options[:pidfile]
        if options[:identifier]
          pidfile ||= DEFAULT_DESCRIPTOR_PIDFILE
          pidfile.sub "%{identifier}", options[:identifier] if pidfile.include?("%{identifier}")
        else
          pidfile || DEFAULT_PIDFILE
        end
      end

      private

      def load_application!(environment)
        ENV["RAILS_ENV"] = environment unless environment.nil?
        require File.expand_path("config/environment.rb")
      end
    end
  end
end
