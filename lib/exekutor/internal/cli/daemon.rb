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

        def pid
          return nil unless ::File.exist? pidfile

          pid = ::File.read(pidfile)
          if pid.to_i.positive?
            pid.to_i
          else
            raise Error, "Corrupt PID-file. Check #{pidfile}"
          end
        end

        # @return [:running, :not_running, :dead, :not_owned]
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

        def status?(*statuses)
          statuses.include? self.status
        end

        # @return [void]
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

        # @return [void]
        def write_pid
          File.open(pidfile, ::File::CREAT | ::File::EXCL | ::File::WRONLY) { |f| f.write(::Process.pid.to_s) }
          at_exit { delete_pid }
        rescue Errno::EEXIST
          validate!
          retry
        end

        # @return [void]
        def delete_pid
          File.delete(pidfile) if File.exist?(pidfile)
        end

        class Error < StandardError; end
      end
    end
  end
end