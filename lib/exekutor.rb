# frozen_string_literal: true

require_relative "exekutor/version"

require "active_job"
require "active_job/queue_adapters"

require_relative "exekutor/configuration"

module Exekutor
  def self.config
    @config ||= Exekutor::Configuration.new
  end

  class Error < StandardError; end
end

require_relative "exekutor/queue"
require_relative "active_job/queue_adapters/exekutor_adapter"

require_relative "exekutor/work/reserver"
require_relative "exekutor/work/executor"
require_relative "exekutor/work/providers/event_provider"
require_relative "exekutor/work/providers/polling_provider"
require_relative "exekutor/work/providers/scheduled_provider"

require_relative "exekutor/worker"

# TODO do we really need an engine?
require_relative "exekutor/engine"
