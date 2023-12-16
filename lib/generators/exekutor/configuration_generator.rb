# frozen_string_literal: true

require "rails/generators"

module Exekutor
  # Generates a YAML configuration file
  class ConfigurationGenerator < Rails::Generators::Base
    desc "Create YAML configuration for Exekutor"

    class_option :identifier, type: :string, aliases: %i[--id], desc: "The worker identifier"

    # Creates the configuration file at +config/exekutor.yml+. Uses the current worker configuration as the base.
    def create_configuration_file
      config = { queues: %w[queues to watch] }.merge(Exekutor.config.worker_options)
      config[:status_port] = 12_677
      config[:set_db_connection_name] = true
      config[:wait_for_termination] = 120

      filename = "config/exekutor#{".#{options[:identifier]}" if options[:identifier]}.yml"
      create_file filename, { "exekutor" => config.stringify_keys }.to_yaml
    end
  end
end
