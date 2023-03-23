# frozen_string_literal: true

module Exekutor
  # @private
  module Internal
    module CLI
      # Manages daemonization of the current process.
      # @private
      class Daemon
        # The path of the generated pidfile.
        # @return [String]
        attr_reader :pidfile

        # @param pidfile [String] Pidfile path
        def initialize(pidfile:)
          @pidfile = pidfile
        end

        # Daemonizes the current process and writes out a pidfile.
        # @return [void]
        def daemonize
          validate!
          ::Process.daemon true
          write_pid
        end

        # The process ID for this daemon, if known
        # @return [Integer,nil] The process ID
        # @raise [Error] if the pid-file is corrupt
        def pid
          return nil unless ::File.exist? pidfile

          pid = ::File.read(pidfile)
          if pid.to_i.positive?
            pid.to_i
          else
            raise Error, "Corrupt PID-file. Check #{pidfile}"
          end
        end

        # The process status for this daemon. Possible states are:
        # - +:running+ when the daemon is running;
        # - +:not_running+ when the daemon is not running;
        # - +:dead+ when the daemon is dead. (Ie. the PID is known, but the process is gone);
        # - +:not_owned+ when the daemon cannot be accessed.
        # @return [:running, :not_running, :dead, :not_owned] the status
        def status
          pid = self.pid
          return :not_running if pid.nil?

          # If sig is 0, then no signal is sent, but error checking is still performed; this can be used to check for the
          # existence of a process ID or process group ID.
          ::Process.kill(0, pid)
          :running
        rescue Errno::ESRCH
          :dead
        rescue Errno::EPERM
          :not_owned
        end

        # Checks whether {#status} matches any of the given statuses.
        # @param statuses [Symbol...] The statuses to check for.
        # @return [Boolean] whether the status matches
        # @see #status
        def status?(*statuses)
          statuses.include? self.status
        end

        # Raises an {Error} if a daemon is already running. Deletes the pidfile is the process is dead.
        # @return [void]
        # @raise [Error] when the daemon is running
        def validate!
          case self.status
          when :running, :not_owned
            raise Error, "A worker is already running. Check #{pidfile}"
          else
            delete_pid
          end
          nil
        end

        private

        # Writes the current process ID to the pidfile. The pidfile will be deleted upon exit.
        # @return [void]
        # @see #pidfile
        # @raise [Error] is the daemon is already running
        def write_pid
          File.open(pidfile, ::File::CREAT | ::File::EXCL | ::File::WRONLY) { |f| f.write(::Process.pid.to_s) }
          at_exit { delete_pid }
        rescue Errno::EEXIST
          validate!
          retry
        end

        # Deletes the pidfile
        # @return [void]
        # @see #pidfile
        def delete_pid
          File.delete(pidfile) if File.exist?(pidfile)
        end

        # Raised when spawning a daemon process fails
        class Error < StandardError; end
      end
    end
  end
end
