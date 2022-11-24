require "gli"
require "rainbow"
require_relative "manager"
require_relative "daemon"

module Exekutor
  # The command line interface for Exekutor
  module CLI
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

      command :start do |c|
        c.desc "Starts a worker"
        c.long_desc <<~TEXT
          Starts a new worker to execute jobs from your ActiveJob queue. If the worker is daemonized this command will
          return immediately.
        TEXT

        c.switch %i[d daemon daemonize], negatable: false,
                 desc: "Run as a background daemon (default: false)"

        App.define_start_options(c)

        c.action do |global_options, options|
          Manager.new(global_options).start(options)
        end
      end

      command :stop do |c|
        c.desc "Stops a daemonized worker"
        c.long_desc <<~TEXT
          Stops a daemonized worker. This uses the PID file to send a shutdown command to a running worker. If the worker 
          does not exit within the shutdown timeout it will kill the process.
        TEXT

        c.switch :all, desc: "Stops all workers with default pid files."
        App.define_stop_options c

        c.action do |global_options, options|
          if options[:all]
            Dir['tmp/pids/exekutor*.pid'].each do |pidfile|
              Manager.new(global_options.merge(pidfile: pidfile)).stop(options)
            end
          else
            Manager.new(global_options).stop(options)
          end
        end
      end

      command :restart do |c|
        c.desc "Restarts a daemonized worker"
        c.long_desc <<~TEXT
          Restarts a daemonized worker. Will issue the stop command if a worker is running and wait for the active worker
          to exit before starting a new worker. If no worker is currently running, a new worker will be started.
        TEXT

        App.define_stop_options c
        App.define_start_options c

        c.action do |global_options, options|
          Manager.new(global_options).restart(options.slice(:shutdown_timeout),
                                              options.reject { |k, _| k == :shutdown_timeout })
        end
      end
    end
  end
end
