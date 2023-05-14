# frozen_string_literal: true

require "rainbow"

# The Exekutor namespace
module Exekutor
  # @private
  module Internal
    # Mixin to use the logger
    module Logger
      extend ActiveSupport::Concern

      included do
        # The log tags to use when writing to the log
        mattr_accessor :log_tags, default: [name.demodulize]
      end

      protected

      # Prints the error to the log
      # @param err [Exception] the error to print
      # @param message [String] the message to print above the error
      # @return [void]
      def log_error(err, message)
        @backtrace_cleaner ||= ActiveSupport::BacktraceCleaner.new
        logger.error message if message
        logger.error "#{err.class} – #{err.message}\nat #{@backtrace_cleaner.clean(err.backtrace).join("\n   ")}"
      end

      # Gets the logger
      # @return [ActiveSupport::TaggedLogging]
      def logger
        @logger ||= Exekutor.logger.tagged(log_tags.compact)
      end
    end
  end

  # Prints a message to STDOUT, unless {Exekutor::Configuration#quiet?} is true
  # @private
  def self.say(*args)
    puts(*args) unless config.quiet? # rubocop:disable Rails/Output
  end

  # Prints the error in the log and to STDERR (unless {Exekutor::Configuration#quiet?} is true)
  # @param error [Exception] the error to print
  # @param message [String] the message to print above the error
  # @return [void]
  def self.print_error(error, message = nil)
    error = strferr(error)
    unless config.quiet?
      warn Rainbow(message).bright.red if message
      warn Rainbow(error).red
    end
    if config.quiet? || !ActiveSupport::Logger.logger_outputs_to?(logger, $stdout)
      logger.error message if message
      logger.error error
    end
    nil
  end

  # Gets the logger
  # @return [ActiveSupport::TaggedLogging]
  mattr_reader :logger, default: ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new($stdout))

  # Sets the logger
  # @param logger [ActiveSupport::Logger]
  def self.logger=(logger)
    raise ArgumentError, "logger must be a logger" unless logger.is_a? Logger

    @logger = if logger.is_a? ActiveSupport::TaggedLogging
                logger
              else
                ActiveSupport::TaggedLogging.new logger
              end
  end

  # @return [ActiveSupport::BacktraceCleaner] A cleaner for error backtraces
  def self.backtrace_cleaner
    @backtrace_cleaner ||= ActiveSupport::BacktraceCleaner.new
  end

  # @return [String] The given error class, message, and cleaned backtrace as a string
  def self.strferr(err)
    raise ArgumentError, "err must not be nil" if err.nil?

    "#{err.class} – #{err.message}\nat #{
      err.backtrace ? backtrace_cleaner.clean(err.backtrace).join("\n   ") : "unknown location"
    }"
  end

  private_class_method :backtrace_cleaner, :strferr
end
