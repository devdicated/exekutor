module Exekutor
  # @private
  module Internal
    module Logger
      extend ActiveSupport::Concern

      included do
        mattr_accessor :log_tags, default: [self.name.demodulize]
      end

      protected

      def log_error(err, message)
        @backtrace_cleaner ||= ActiveSupport::BacktraceCleaner.new
        logger.error message if message
        logger.error "#{err.class} – #{err.message}\nat #{@backtrace_cleaner.clean(err.backtrace).join("\n   ")}"
      end

      def logger
        @logger ||= Exekutor.logger.tagged(log_tags.compact)
      end
    end
  end

  def self.say(*args)
    puts(*args) unless config.quiet?
  end

  def self.print_error(err, message = nil)
    @backtrace_cleaner ||= ActiveSupport::BacktraceCleaner.new
    error = "#{err.class} – #{err.message}\nat #{@backtrace_cleaner.clean(err.backtrace).join("\n   ")}"

    unless config.quiet?
      puts Rainbow(message).bright.red if message
      puts Rainbow(error).red
    end

    logger.fatal message if message
    logger.fatal error
  end

  mattr_reader :logger, default: ActiveSupport::TaggedLogging.new(Logger.new(STDOUT))

  def self.logger=(logger)
    @logger = ActiveSupport::TaggedLogging.new logger
  end
end