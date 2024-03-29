# frozen_string_literal: true

require "gli"
require "rainbow"
require_relative "cleanup"
require_relative "info"
require_relative "manager"

module Exekutor
  # @private
  module Internal
    # The internal command line interface for Exekutor
    # @private
    module CLI
      # Converts the command line arguments to Manager calls
      # @private
      class App
        extend GLI::App

        program_desc "Exekutor CLI"
        version Exekutor::VERSION

        default_command :start

        flag %i[id identifier], default_value: nil,
             desc: "Descriptor of the worker instance, is used in the pid file and shown in the worker info"
        flag %i[pid pidfile], default_value: Manager::DEFAULT_PIDFILE,
             desc: "Path to write daemonized Process ID"

        switch %i[v verbose], negatable: false, desc: "Enable more output"
        switch %i[quiet], negatable: false, desc: "Enable less output"

        # Defines start command flags
        def self.define_start_options(cmd)
          cmd.flag %i[env environment], desc: "The Rails environment"
          cmd.flag %i[q queue], default_value: Manager::DEFAULT_QUEUE, multiple: true,
                   desc: "Queue to work from"
          cmd.flag %i[p priority], type: String, default_value: Manager::DEFAULT_PRIORITIES,
                   desc: "The job priorities to execute, specified as `min` or `min:max`"
          cmd.flag %i[t threads], type: String, default_value: Manager::DEFAULT_THREADS,
                   desc: "The number of threads for executing jobs, specified as `min:max`"
          cmd.flag %i[i poll_interval], type: Integer, default_value: DefaultOptionValue.new(value: 60),
                   desc: "Interval between polls for available jobs (in seconds)"
          cmd.flag %i[cfg configfile], type: String, default_value: Manager::DEFAULT_CONFIG_FILES, multiple: true,
                   desc: "The YAML configuration file to load. If specifying multiple files, the last file takes " \
                         "precedence"
        end

        private_class_method :define_start_options

        # Defines stop command flags
        def self.define_stop_options(cmd)
          cmd.flag %i[timeout shutdown_timeout], default_value: Manager::DEFAULT_FOREVER,
                   desc: "Number of seconds to wait for jobs to finish when shutting down before killing the worker. " \
                         "(in seconds)"
        end

        private_class_method :define_stop_options

        desc "Starts a worker"
        long_desc <<~TEXT
          Starts a new worker to execute jobs from your ActiveJob queue. If the worker is daemonized this command will
          return immediately.
        TEXT
        command :start do |c|
          c.switch %i[d daemon daemonize], negatable: false,
                   desc: "Run as a background daemon (default: false)"

          define_start_options(c)

          c.action do |global_options, options|
            Manager.new(global_options).start(options)
          end
        end

        desc "Stops a daemonized worker"
        long_desc <<~TEXT
          Stops a daemonized worker. This uses the PID file to send a shutdown command to a running worker. If the
          worker does not exit within the shutdown timeout it will kill the process.
        TEXT
        command :stop do |c|
          c.switch :all, negatable: false, desc: "Stops all workers with default pid files."
          define_stop_options c

          c.action do |global_options, options|
            if options[:all]
              unless global_options[:identifier].nil? || global_options[:quiet]
                puts "The identifier option is ignored for --all"
              end
              pidfile_pattern = if options[:pidfile].nil? || options[:pidfile] == Manager::DEFAULT_PIDFILE
                                  "tmp/pids/exekutor*.pid"
                                else
                                  options[:pidfile]
                                end
              pidfiles = Dir[pidfile_pattern]
              if pidfiles.any?
                pidfiles.each do |pidfile|
                  Manager.new(global_options.merge(pidfile: pidfile)).stop(options)
                end
              else
                puts "There are no running workers (No pidfiles found for `#{pidfile_pattern}`)"
              end
            else
              Manager.new(global_options).stop(options)
            end
          end
        end

        desc "Restarts a daemonized worker"
        long_desc <<~TEXT
          Restarts a daemonized worker. Will issue the stop command if a worker is running and wait for the active
          worker to exit before starting a new worker. If no worker is currently running, a new worker will be started.
        TEXT
        command :restart do |c|
          define_stop_options c
          define_start_options c

          c.action do |global_options, options|
            Manager.new(global_options).restart(options.slice(:shutdown_timeout),
                                                options.except(:shutdown_timeout))
          end
        end

        desc "Prints worker and job info"
        long_desc <<~TEXT
          Prints info about workers and pending jobs.
        TEXT
        command :info do |c|
          c.flag %i[env environment], desc: "The Rails environment."

          c.action do |global_options, options|
            Info.new(global_options).print(options)
          end
        end

        desc "Cleans up workers and jobs"
        long_desc <<~TEXT
          Cleans up the finished jobs and stale workers
        TEXT
        command :cleanup do |c| # rubocop:disable Metrics/BlockLength
          c.flag %i[env environment], desc: "The Rails environment."

          c.flag %i[t timeout],
                 desc: "The global timeout in hours. Workers and jobs before the timeout will be purged"
          c.flag %i[worker_timeout],
                 default_value: 4,
                 desc: "The worker timeout in hours. Workers where the last heartbeat is before the timeout will be " \
                       "deleted."
          c.flag %i[job_timeout],
                 default_value: 48,
                 desc: "The job timeout in hours. Jobs where scheduled at is before the timeout will be purged."
          c.flag %i[s job_status],
                 default_value: Cleanup::DEFAULT_STATUSES, multiple: true,
                 desc: "The statuses to purge. Only jobs with this status will be purged."

          c.default_command :all

          c.desc "Cleans up both the workers and the jobs"
          c.command(:all) do |ac|
            ac.action do |global_options, options|
              Cleanup.new(global_options).tap do |cleaner|
                cleaner.cleanup_workers(options.merge(print_header: true))
                cleaner.cleanup_jobs(options.merge(print_header: true))
              end
            end
          end
          c.desc "Cleans up the workers table"
          c.command(:workers, :w) do |wc|
            wc.action do |global_options, options|
              Cleanup.new(global_options).cleanup_workers(options)
            end
          end
          c.desc "Cleans up the jobs table"
          c.command(:jobs, :j) do |jc|
            jc.action do |global_options, options|
              Cleanup.new(global_options).cleanup_jobs(options)
            end
          end
        end
      end
    end
  end
end
