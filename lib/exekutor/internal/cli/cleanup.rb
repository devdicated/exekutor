require_relative "default_option_value"
require "terminal-table"

module Exekutor
  # @private
  module Internal
    module CLI
      # Cleanup for the CLI
      # @private
      class Cleanup

        def initialize(options)
          @global_options = options
          @delegate = ::Exekutor::Cleanup.new
        end

        def cleanup_workers(options)
          load_application options[:environment]

          ActiveSupport.on_load(:active_record, yield: true) do
            # Use system time zone
            Time.zone = Time.new.zone

            timeout = options[:timeout] || options[:worker_timeout] || 4
            workers = @delegate.cleanup_workers timeout.hours
            return if quiet?

            puts Rainbow("Workers").bright.blue if options[:print_header]
            if workers.present?
              puts "Purged #{workers.size} worker#{"s" if workers.many?}"
              if verbose?
                table = Terminal::Table.new
                table.headings = ["id", "Last heartbeat"]
                workers.each { |w| table << [w.id.split("-").first << "…", w.last_heartbeat_at] }
                puts table
              end
            else
              puts "Nothing purged"
            end
          end
        end

        def cleanup_jobs(options)
          load_application options[:environment]
          ActiveSupport.on_load(:active_record, yield: true) do
            # Use system time zone
            Time.zone = Time.new.zone

            timeout = options[:timeout] || options[:job_timeout] || 48
            status = if options[:job_status].is_a? Array
                       options[:job_status]
                     elsif options[:job_status] && options[:job_status] != DEFAULT_STATUSES
                       options[:job_status]
                     end
            purged_count = @delegate.cleanup_jobs before: timeout.hours.ago, status: status
            return if quiet?

            puts Rainbow("Jobs").bright.blue if options[:print_header]
            if purged_count.zero?
              puts "Nothing purged"
            else
              puts "Purged #{purged_count} job#{"s" if purged_count > 1}"
            end
          end
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

        def load_application(environment, path = "config/environment.rb")
          return if @loaded
          ENV["RAILS_ENV"] = environment unless environment.nil?
          require File.expand_path(path)
          @loaded = true
        end

        DEFAULT_STATUSES = DefaultOptionValue.new("All except :pending").freeze
      end
    end

  end
end