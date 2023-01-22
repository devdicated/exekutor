# frozen_string_literal: true

require_relative "exekutor/version"

module Exekutor

  # Base error class
  class Error < StandardError; end

  # Error that can be raised during job execution causing the job to be discarded
  class DiscardJob < Exception
    # Use Exception as base class so it is less likely to be caught in rescue blocks
  end
end

require_relative "exekutor/queue"
require_relative "active_job/queue_adapters/exekutor_adapter"

require_relative "exekutor/plugins"
require_relative "exekutor/configuration"
require_relative "exekutor/job_options"

require_relative "exekutor/info/worker"
require_relative "exekutor/job"
require_relative "exekutor/job_error"

require_relative "exekutor/internal/database_connection"
require_relative "exekutor/internal/logger"

require_relative "exekutor/internal/executor"
require_relative "exekutor/internal/reserver"
require_relative "exekutor/internal/provider"
require_relative "exekutor/internal/listener"
require_relative "exekutor/internal/hooks"

require_relative "exekutor/asynchronous"
require_relative "exekutor/cleanup"
require_relative "exekutor/healthcheck_server"
require_relative "exekutor/hook"
require_relative "exekutor/worker"

Exekutor.private_constant "Internal"
ActiveSupport.run_load_hooks(:exekutor, Exekutor)
