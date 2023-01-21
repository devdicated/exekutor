module Exekutor
  module Plugins
    class LoadError < ::LoadError; end
  end

  def self.load_plugin(name)
    if File.exists? File.join(__dir__, "plugins/#{name}.rb")
      require_relative "plugins/#{name}"
    else
      raise Plugins::LoadError, "The #{name} plugin does not exist. Have you spelled it correctly?"
    end
  end
end