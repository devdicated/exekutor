module Exekutor
  module Internal
    module CLI
      module ApplicationLoader
        LOADING_MESSAGE = "Loading Rails environment…"

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