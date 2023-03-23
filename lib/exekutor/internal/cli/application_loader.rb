# frozen_string_literal: true

module Exekutor
  module Internal
    module CLI
      # Helper methods to load the Rails application
      module ApplicationLoader
        # The message to print when loading the Rails application
        LOADING_MESSAGE = "Loading Rails environment…"

        # Loads the Rails application
        # @param environment [String] the environment to load (eg. development, production)
        # @param path [String] the path to the environment file
        # @param print_message [Boolean] whether to print a loading message to STDOUT
        def load_application(environment, path = "config/environment.rb", print_message: false)
          return if @application_loaded
          if print_message
            printf LOADING_MESSAGE
            @loading_message_printed = true
          end
          ENV["RAILS_ENV"] = environment unless environment.nil?
          require File.expand_path(path)
          @application_loaded = true
        end

        # Clears the loading message if it was printed
        def clear_application_loading_message
          if @loading_message_printed
            printf "\r#{" " * LOADING_MESSAGE.length}\r"
            @loading_message_printed = false
          end
        end

      end
    end
  end

end
