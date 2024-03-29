# frozen_string_literal: true

require_relative "exekutor/version"

# The Exekutor namespace
module Exekutor
  # Base error class
  class Error < StandardError; end

  # Error that can be raised during job execution causing the job to be discarded
  class DiscardJob < StandardError; end
end

require_relative "exekutor/queue"

require_relative "exekutor/plugins"
require_relative "exekutor/configuration"
require_relative "exekutor/job_options"

require_relative "exekutor/internal/database_connection"
require_relative "exekutor/internal/logger"

require_relative "exekutor/internal/executor"
require_relative "exekutor/internal/reserver"
require_relative "exekutor/internal/provider"
require_relative "exekutor/internal/listener"
require_relative "exekutor/internal/hooks"

require_relative "exekutor/asynchronous"
require_relative "exekutor/cleanup"
require_relative "exekutor/internal/status_server"
require_relative "exekutor/hook"
require_relative "exekutor/worker"

ActiveSupport.on_load(:active_job) do
  require_relative "active_job/queue_adapters/exekutor_adapter"
end

ActiveSupport.on_load(:active_record) do
  # Wait until the Rails app is initialized so Exekutor.config.base_record_class can be set.
  ActiveSupport.on_load(:after_initialize) do
    require_relative "exekutor/info/worker"
    require_relative "exekutor/job"
    require_relative "exekutor/job_error"
  end
end

Exekutor.private_constant :Internal
ActiveSupport.run_load_hooks(:exekutor, Exekutor)
