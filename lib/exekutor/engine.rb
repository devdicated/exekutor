# frozen_string_literal: true
module Exekutor
  # Ruby on Rails integration.
  class Engine < ::Rails::Engine
    isolate_namespace Exekutor

    config.exekutor = Exekutor.config

    initializer "exekutor.logger" do |_app|
      ActiveSupport.on_load(:exekutor) do
        # self.logger = ::Rails.logger if Exekutor.config.logger == Exekutor::Configuration::DEFAULT_VALUE
      end
    end
  end
end
