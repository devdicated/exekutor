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
            # Use system time zone
            Time.zone = Time.new.zone

            hosts = Exekutor::Info::Worker.distinct.pluck(:hostname)
            job_info = Exekutor::Job.pending.order(:queue).group(:queue)
                                    .pluck(:queue, Arel.sql("COUNT(*)"), Arel.sql("MIN(scheduled_at)"))

            clear_application_loading_message unless quiet?
            puts Rainbow("Workers").bright.blue
            if hosts.present?
              total_workers = 0
              hosts.each do |host|
                table = Terminal::Table.new
                table.title = host if hosts.many?
                table.headings = ["id", "Status", "Last heartbeat"]
                worker_count = 0
                Exekutor::Info::Worker.where(hostname: host).each do |worker|
                  worker_count += 1
                  table << [
                    worker.id.split("-").first << "…",
                    worker.status,
                    if worker.last_heartbeat_at.nil?
                      if !worker.running?
                        "N/A"
                      elsif worker.created_at < 10.minutes.ago
                        Rainbow("None").red
                      else
                        "None"
                      end
                    elsif worker.last_heartbeat_at > 2.minutes.ago
                      worker.last_heartbeat_at.strftime "%R"
                    elsif worker.last_heartbeat_at > 10.minutes.ago
                      Rainbow(worker.last_heartbeat_at.strftime("%R")).yellow
                    else
                      Rainbow(worker.last_heartbeat_at.strftime("%D %R")).red
                    end
                  ]
                  # TODO: switch / flag to print threads and queues
                end
                total_workers += worker_count
                table.add_separator
                table.add_row [(hosts.many? ? "Subtotal" : "Total"), { value: worker_count, alignment: :right, colspan: 2 }]
                puts table
              end

              if hosts.many?
                puts Terminal::Table.new rows: [
                  ["Total hosts", hosts.size],
                  ["Total workers", total_workers]
                ]
              end
            else
              message = Rainbow("There are no active workers")
              message = message.red if job_info.present?
              puts message
            end

            puts " "
            puts "#{Rainbow("Jobs").bright.blue}"
            if job_info.present?
              table = Terminal::Table.new
              table.headings = ["Queue", "Pending jobs", "Next job scheduled at"]
              total_count = 0
              job_info.each do |queue, count, min_scheduled_at|
                table << [
                  queue, count,
                  if min_scheduled_at.nil?
                    "N/A"
                  elsif min_scheduled_at < 30.minutes.ago
                    Rainbow(min_scheduled_at.strftime("%D %R")).red
                  elsif min_scheduled_at < 1.minute.ago
                    Rainbow(min_scheduled_at.strftime("%D %R")).yellow
                  else
                    min_scheduled_at.strftime("%D %R")
                  end
                ]
                total_count += count
              end
              if job_info.many?
                table.add_separator
                table.add_row ["Total", { value: total_count, alignment: :right, colspan: 2 }]
              end
              puts table
            else
              puts Rainbow("No pending jobs").green
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
      end
    end
  end
end
