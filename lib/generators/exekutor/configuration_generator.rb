# frozen_string_literal: true

require "rails/generators"

module Exekutor
  # Generates a YAML configuration file
  class ConfigurationGenerator < Rails::Generators::Base
    desc "Create YAML configuration for Exekutor"

    class_option :identifier, type: :string, aliases: %i[--id], desc: "The worker identifier"

    # Creates the configuration file at +config/exekutor.yml+. Uses the current worker configuration as the base.
    def create_configuration_file
      config = { queues: %w[queues to watch] }
      config.merge! Exekutor.config.worker_options
                            .without(:enable_listener, :set_db_connection_name, :delete_completed_jobs,
                                     :delete_discarded_jobs, :delete_failed_jobs)
      config[:status_server_port] ||= 12_677
      config[:wait_for_termination] ||= 120
      transform_durations(config)

      filename = "config/exekutor#{".#{options[:identifier]}" if options[:identifier]}.yml"
      create_file filename, { "exekutor" => config.stringify_keys }.to_yaml
    end

    private

    def transform_durations(config)
      config.select { |_, v| v.is_a? ActiveSupport::Duration }
            .each do |key, value|
        config[key] = if key == :healthcheck_timeout
                        value.to_i / 60
                      else
                        value.to_i
                      end
      end
    end
  end
end
