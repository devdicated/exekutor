# frozen_string_literal: true

require_relative "exekutor/version"

require_relative "exekutor/configuration"
require_relative "exekutor/logger"

require_relative "exekutor/queue"
require_relative "active_job/queue_adapters/exekutor_adapter"

require_relative "exekutor/executable"
require_relative "exekutor/connection"

require_relative "exekutor/jobs/reserver"
require_relative "exekutor/jobs/executor"
require_relative "exekutor/jobs/provider"
require_relative "exekutor/jobs/listener"

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

  class Error < StandardError; end
end

require_relative "exekutor/worker"
# TODO do we really need an engine?
require_relative "exekutor/engine"

ActiveSupport.run_load_hooks(:exekutor, self)
