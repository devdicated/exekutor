# frozen_string_literal: true

module Exekutor
  module Plugins
    # Raised when a plugin cannot be loaded
    class LoadError < ::LoadError; end
  end

  def self.load_plugin(name)
    unless File.exist? File.join(__dir__, "plugins/#{name}.rb")
      raise Plugins::LoadError, "The #{name} plugin does not exist. Have you spelled it correctly?"
    end

    require_relative "plugins/#{name}"
  end
end
