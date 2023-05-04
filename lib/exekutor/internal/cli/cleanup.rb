# frozen_string_literal: true

require_relative "application_loader"
require_relative "default_option_value"
require "terminal-table"

module Exekutor
  # @private
  module Internal
    module CLI
      # Cleanup for the CLI
      # @private
      class Cleanup
        include ApplicationLoader

        def initialize(options)
          @global_options = options
        end

        # Cleans up the workers table
        # @see Exekutor::Cleanup
        def cleanup_workers(options)
          load_application options[:environment], print_message: !quiet?

          ActiveSupport.on_load(:active_record, yield: true) do
            clear_application_loading_message
            print_time_zone_warning if different_time_zone? && !quiet?

            timeout = worker_cleanup_timeout(options)
            workers = cleaner.cleanup_workers timeout: timeout.hours

            print_worker_cleanup_result(options, workers) unless quiet?
          end
        end

        # Cleans up the jobs table
        # @see Exekutor::Cleanup
        def cleanup_jobs(options)
          load_application options[:environment], print_message: !quiet?

          ActiveSupport.on_load(:active_record, yield: true) do
            clear_application_loading_message
            print_time_zone_warning if different_time_zone? && !quiet?

            timeout = job_cleanup_timeout(options)
            purged_count = cleaner.cleanup_jobs before: timeout.hours.ago, status: job_cleanup_statuses(options)

            print_job_cleanup_result(options, purged_count) unless quiet?
          end
        end

        private

        def job_cleanup_statuses(options)
          options[:job_status] if options[:job_status] && options[:job_status] != DEFAULT_STATUSES
        end

        def job_cleanup_timeout(options)
          options[:timeout] || options[:job_timeout] || 48
        end

        def print_job_cleanup_result(options, purged_count)
          puts Rainbow("Jobs").bright.blue if options[:print_header]
          if purged_count.zero?
            puts "Nothing purged"
          else
            puts "Purged #{purged_count} job#{"s" if purged_count > 1}"
          end
        end

        def worker_cleanup_timeout(options)
          options[:timeout] || options[:worker_timeout] || 4
        end

        def print_worker_cleanup_result(options, workers)
          puts Rainbow("Workers").bright.blue if options[:print_header]
          if workers.present?
            puts "Purged #{workers.size} worker#{"s" if workers.many?}"
            print_worker_info(workers) if verbose?
          else
            puts "Nothing purged"
          end
        end

        def print_worker_info(workers)
          table = Terminal::Table.new
          table.headings = ["id", "Last heartbeat"]
          workers.each { |w| table << [w.id.split("-").first << "…", w.last_heartbeat_at] }
          puts table
        end

        # @return [Boolean] Whether quiet mode is enabled. Overrides verbose mode.
        def quiet?
          !!@global_options[:quiet]
        end

        # @return [Boolean] Whether verbose mode is enabled. Always returns false if quiet mode is enabled.
        def verbose?
          !quiet? && !!@global_options[:verbose]
        end

        def cleaner
          @cleaner ||= ::Exekutor::Cleanup.new
        end

        DEFAULT_STATUSES = DefaultOptionValue.new("All except :pending").freeze
      end
    end
  end
end
