require "rainbow"

module Exekutor
  # @private
  module Internal
    # Mixin to use the logger
    module Logger
      extend ActiveSupport::Concern

      included do
        # The log tags to use when writing to the log
        mattr_accessor :log_tags, default: [self.name.demodulize]
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
    puts(*args) unless config.quiet?
  end

  # Prints the error in the log and to STDERR (unless {Exekutor::Configuration#quiet?} is true)
  # @param err [Exception] the error to print
  # @param message [String] the message to print above the error
  # @return [void]
  def self.print_error(err, message = nil)
    @backtrace_cleaner ||= ActiveSupport::BacktraceCleaner.new
    error = "#{err.class} – #{err.message}\nat #{@backtrace_cleaner.clean(err.backtrace).join("\n   ")}"

    unless config.quiet?
      STDERR.puts Rainbow(message).bright.red if message
      STDERR.puts Rainbow(error).red
    end
    unless ActiveSupport::Logger.logger_outputs_to?(logger, STDOUT)
      logger.fatal message if message
      logger.fatal error
    end
  end

  # Gets the logger
  # @return [ActiveSupport::TaggedLogging]
  mattr_reader :logger, default: ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(STDOUT))

  # Sets the logger
  # @param logger [ActiveSupport::Logger]
  def self.logger=(logger)
    @logger = if logger.is_a? ActiveSupport::TaggedLogging
                logger
              else
                ActiveSupport::TaggedLogging.new logger
              end
  end
end