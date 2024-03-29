# frozen_string_literal: true

require_relative "application_loader"
require "terminal-table"

module Exekutor
  # @private
  module Internal
    module CLI
      # Prints info for the CLI
      # @private
      class Info
        include ApplicationLoader

        def initialize(options)
          @global_options = options
        end

        # Prints Exekutor info to STDOUT
        def print(options)
          load_application(options[:environment], print_message: !quiet?)

          ActiveSupport.on_load(:active_record, yield: true) do
            clear_application_loading_message
            print_time_zone_warning if different_time_zone? && !quiet?

            hosts = Exekutor::Info::Worker.distinct.pluck(:hostname)
            job_info = pending_jobs_per_queue

            print_workers(hosts, job_info.present?, options)
            puts
            print_jobs(job_info)
          end
        end

        private

        def pending_jobs_per_queue
          Exekutor::Job.pending.order(:queue).group(:queue)
                       .pluck(:queue, Arel.sql("COUNT(*)"), Arel.sql("MIN(scheduled_at)"))
        end

        def print_jobs(job_info)
          puts Rainbow("Jobs").bright.blue
          if job_info.present?
            puts create_job_info_table(job_info)
          else
            puts Rainbow("No pending jobs").green
          end
        end

        def create_job_info_table(job_info)
          Terminal::Table.new(headings: ["Queue", "Pending jobs", "Next job scheduled at"]).tap do |table|
            total_count = 0
            job_info.each do |queue, count, min_scheduled_at|
              table << [queue, { value: count, alignment: :right }, format_scheduled_at(min_scheduled_at)]
              total_count += count
            end
            if job_info.many?
              table.add_separator
              table << ["Total", { value: total_count, alignment: :right, colspan: 2 }]
            end
          end
        end

        def format_scheduled_at(min_scheduled_at)
          if min_scheduled_at.nil?
            "N/A"
          elsif min_scheduled_at < 30.minutes.ago
            Rainbow(min_scheduled_at.strftime("%D %R")).red
          elsif min_scheduled_at < 1.minute.ago
            Rainbow(min_scheduled_at.strftime("%D %R")).yellow
          else
            min_scheduled_at.strftime("%D %R")
          end
        end

        def print_workers(hosts, has_pending_jobs, options)
          puts Rainbow("Workers").bright.blue
          if hosts.present?
            total_workers = 0
            hosts.each do |host|
              total_workers += print_host_info(host, options.merge(many_hosts: hosts.many?))
            end

            if hosts.many?
              puts Terminal::Table.new rows: [
                ["Total hosts", hosts.size],
                ["Total workers", total_workers]
              ]
            end
          else
            message = Rainbow("There are no active workers")
            message = message.red if has_pending_jobs
            puts message
          end
        end

        def print_host_info(host, options)
          many_hosts = options[:many_hosts]
          table = Terminal::Table.new headings: ["id", "Status", "Last heartbeat"]
          table.title = host if many_hosts
          worker_count = 0
          Exekutor::Info::Worker.where(hostname: host).find_each do |worker|
            worker_count += 1
            table << worker_info_row(worker)
          end
          table.add_separator
          table.add_row [(many_hosts ? "Subtotal" : "Total"),
                         { value: worker_count, alignment: :right, colspan: 2 }]
          puts table
          worker_count
        end

        def worker_info_row(worker)
          [
            worker.id.split("-").first << "…",
            worker.status,
            worker_heartbeat_column(worker)
          ]
        end

        def worker_heartbeat_column(worker)
          last_heartbeat_at = worker.last_heartbeat_at
          if last_heartbeat_at
            colorize_heartbeat(last_heartbeat_at)
          elsif !worker.running?
            "N/A"
          elsif worker.started_at < 10.minutes.ago
            Rainbow("None").red
          else
            "None"
          end
        end

        def colorize_heartbeat(timestamp)
          case Time.now - timestamp
          when (10.minutes)..nil
            Rainbow(timestamp.strftime("%D %R")).red
          when (2.minutes)..(10.minutes)
            Rainbow(timestamp.strftime("%R")).yellow
          else
            timestamp.strftime "%R"
          end
        end

        # @return [Boolean] Whether quiet mode is enabled. Overrides verbose mode.
        def quiet?
          !!@global_options[:quiet]
        end

        # @return [Boolean] Whether verbose mode is enabled. Always returns false if quiet mode is enabled.
        def verbose?
          !quiet? && !!@global_options[:verbose]
        end
      end
    end
  end
end
