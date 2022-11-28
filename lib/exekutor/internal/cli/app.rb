require "gli"
require "rainbow"
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

        default_command :start

        flag %i[id identifier], default_value: nil,
             desc: "Descriptor of the worker instance, is used in the pid file and shown in the worker info"
        flag %i[pid pidfile], default_value: Manager::DEFAULT_PIDFILE,
             desc: "Path to write daemonized Process ID"

        switch %i[v verbose], negatable: false, desc: "Enable more output"
        switch %i[quiet], negatable: false, desc: "Enable less output"

        def self.define_start_options(c)
          c.flag %i[env environment], desc: "The Rails environment."
          c.flag %i[q queue], default_value: Manager::DEFAULT_QUEUE, multiple: true,
                 desc: "Queue to work from."
          c.flag %i[t max_threads], type: Integer, default_value: Manager::DEFAULT_MAX_THREADS,
                 desc: "Maximum number of threads for executing jobs."
          c.flag %i[p poll_interval], type: Integer, default_value: 60,
                 desc: "Interval between polls for available jobs (in seconds)"
        end

        def self.define_stop_options(c)
          c.flag %i[timeout shutdown_timeout], default_value: Manager::DEFAULT_FOREVER,
                 desc: "Number of seconds to wait for jobs to finish when shutting down before killing the worker. (in seconds)"
        end

        desc "Starts a worker"
        long_desc <<~TEXT
          Starts a new worker to execute jobs from your ActiveJob queue. If the worker is daemonized this command will
          return immediately.
        TEXT
        command :start do |c|
          c.switch %i[d daemon daemonize], negatable: false,
                   desc: "Run as a background daemon (default: false)"

          App.define_start_options(c)

          c.action do |global_options, options|
            Manager.new(global_options).start(options)
          end
        end

        desc "Stops a daemonized worker"
        long_desc <<~TEXT
          Stops a daemonized worker. This uses the PID file to send a shutdown command to a running worker. If the worker 
          does not exit within the shutdown timeout it will kill the process.
        TEXT
        command :stop do |c|
          c.switch :all, desc: "Stops all workers with default pid files."
          App.define_stop_options c

          c.action do |global_options, options|
            if options[:all]
              puts "The identifier option is ignored for --all" unless global_options[:identifier].nil? || global_options[:quiet]
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
          Restarts a daemonized worker. Will issue the stop command if a worker is running and wait for the active worker
          to exit before starting a new worker. If no worker is currently running, a new worker will be started.
        TEXT
        command :restart do |c|
          App.define_stop_options c
          App.define_start_options c

          c.action do |global_options, options|
            Manager.new(global_options).restart(options.slice(:shutdown_timeout),
                                                options.reject { |k, _| k == :shutdown_timeout })
          end
        end

        desc "Prints Exekutor info"
        long_desc <<~TEXT
          Prints info about workers and pending jobs.
        TEXT
        command :info do |c|
          c.action do |global_options, options|
            Manager.new(global_options).info(options)
          end
        end
      end
    end
  end
end