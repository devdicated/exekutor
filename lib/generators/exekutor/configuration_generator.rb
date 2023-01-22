# frozen_string_literal: true
require 'rails/generators'

module Exekutor
  class ConfigurationGenerator < Rails::Generators::Base
    desc 'Create YAML configuration for Exekutor'

    class_option :identifier, type: :string, aliases: %i(--id), desc: "The worker identifier"

    def create_configuration_file
      config = { queues: %w[queues to watch] }.merge(Exekutor.config.worker_options)
      config[:healthcheck_port] = 8765
      config[:set_db_connection_name] = true
      config[:wait_for_termination] = 120
      create_file "config/exekutor#{".#{options[:identifier]}" if options[:identifier]}.yml", { "exekutor" => config.stringify_keys }.to_yaml
    end
  end
end