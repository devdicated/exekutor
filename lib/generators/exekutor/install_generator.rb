# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Exekutor
  # Generates the initializer and migrations
  class InstallGenerator < Rails::Generators::Base
    include ActiveRecord::Generators::Migration
    desc "Create migrations for Exekutor"

    TEMPLATE_DIR = File.join(__dir__, "templates/install")
    source_paths << TEMPLATE_DIR

    # Creates the initializer file at +config/initializers/exekutor.rb+
    def create_initializer_file
      template "initializers/exekutor.rb.erb", "config/initializers/exekutor.rb"
    end

    # Creates the migration file in the migrations folder
    def create_migration_file
      migration_template "migrations/create_exekutor_schema.rb.erb",
                         File.join(db_migrate_path, "create_exekutor_schema.rb")
      create_fx_files
    end

    protected

    def migration_version
      ActiveRecord::VERSION::STRING.to_f
    end

    def function_sql(name)
      File.read File.join(TEMPLATE_DIR, "functions/#{name}.sql")
    end

    def trigger_sql(name)
      File.read File.join(TEMPLATE_DIR, "triggers/#{name}.sql")
    end

    private

    def create_fx_files
      return unless defined?(Fx)

      %w[job_notifier requeue_orphaned_jobs].each do |function|
        copy_file "functions/#{function}.sql", Fx::Definition.new(name: function, version: 1).full_path
      end
      %w[notify_workers requeue_orphaned_jobs].each do |trigger|
        copy_file "triggers/#{trigger}.sql", Fx::Definition.new(name: trigger, version: 1, type: "trigger").full_path
      end
    end
  end
end
