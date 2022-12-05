# frozen_string_literal: true

require_relative "exekutor/version"

module Exekutor
  def self.say(*args)
    say!(*args) if config.verbose?
  end

  def self.say!(*args)
    puts(*args)
  end

  def self.print_error(err, message = nil)
    @cleaner ||= ActiveSupport::BacktraceCleaner.new
    printf "\033[31m"
    puts message if message
    puts "#{err.class} – #{err.message}"
    puts "at #{@cleaner.clean(err.backtrace).join("\n   ")}"
    printf "\033[0m"
  end

  # Base error class
  class Error < StandardError; end

  # Error that can be raised during jo execution causing the job to be discarded
  class DiscardJob < Exception
    # Use Exception as base class so it is less likely to be caught in Timeout::timeout blocks
  end

end

require_relative "exekutor/queue"
require_relative "active_job/queue_adapters/exekutor_adapter"

require_relative "exekutor/configuration"
require_relative "exekutor/asynchronous"
require_relative "exekutor/job_options"

require_relative "exekutor/internal/connection"
require_relative "exekutor/internal/logger"

require_relative "exekutor/internal/executor"
require_relative "exekutor/internal/reserver"
require_relative "exekutor/internal/provider"
require_relative "exekutor/internal/listener"

require_relative "exekutor/worker"
# TODO do we really need an engine?
require_relative "exekutor/engine"

Exekutor.private_constant "Internal"
ActiveSupport.run_load_hooks(:exekutor, self)
