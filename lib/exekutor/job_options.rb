# frozen_string_literal: true

module Exekutor
  # Mixin which defines custom job options for Exekutor. This module should be included in your job class.
  # You can define the following options after including this module:
  #
  # ==== Queue timeout
  #   MyJob.set(queue_timeout: 1.hour).perform_later
  # How long the job is allowed to be in the queue. If a job is not performed before this timeout, it will be discarded.
  # The value should be a +ActiveSupport::Duration+.
  #
  # ==== Execution timeout
  #   MyJob.set(execution_timeout: 1.minute).perform_later
  # How long the job is allowed to run. If a job is taking longer than this timeout, it will be killed and discarded.
  # The value should be a +ActiveSupport::Duration+. Be aware that +Timeout::timeout+ is used internally for this, which
  # can raise an error at any line of code in your application. <em>Use with caution</em>
  #
  # == Usage
  # === +#set+
  # You can specify the options per job when enqueueing the job using +#set+.
  #   MyJob.set(option_name: @option_value).perform_later
  #
  # === +#exekutor_options+
  # You can also specify options that apply to all instances of a job by calling {#exekutor_options}.
  #  class MyOtherJob < ActiveJob::Base
  #     include Exekutor::JobOptions
  #     exekutor_options execution_timeout: 10.seconds
  #   end
  #
  # *NB* These options only work for jobs that are scheduled with +#perform_later+, the options are ignored when you
  # perform the job immediately using +#perform_now+.
  module JobOptions
    extend ActiveSupport::Concern

    # @private
    VALID_EXEKUTOR_OPTIONS = %i[queue_timeout execution_timeout].freeze
    private_constant "VALID_EXEKUTOR_OPTIONS"

    # @return [Hash<Symbol, Object>] the exekutor options for this job
    attr_reader :exekutor_options

    # @!visibility private
    def enqueue(options = {})
      # :nodoc:
      @exekutor_options = self.class.exekutor_job_options || {}
      job_options = options&.slice(*VALID_EXEKUTOR_OPTIONS)
      if job_options
        self.class.validate_exekutor_options! job_options
        @exekutor_options = @exekutor_options.merge job_options
      end
      super(options)
    end

    class_methods do
      # Sets the exekutor options that apply to all instances of this job. These options can be overwritten with +#set+.
      # @param options [Hash<Symbol, Object>] the exekutor options
      # @option options [ActiveSupport::Duration] :queue_timeout The queue timeout
      # @option options [ActiveSupport::Duration] :execution_timeout The execution timeout
      # @return [void]
      def exekutor_options(options)
        validate_exekutor_options! options
        @exekutor_job_options = options
      end

      # Gets the exekutor options that apply to all instances of this job. These options may be overwritten by +#set+.
      # @return [Hash<Symbol, Object>] the options
      def exekutor_job_options
        @exekutor_job_options if defined?(@exekutor_job_options)
      end

      # Validates the exekutor job options passed to {#exekutor_options} and +#set+
      # @param options [Hash<Symbol, Object>] the options to validate
      # @raise [InvalidOption] if any of the options are invalid
      # @private
      # @return [void]
      def validate_exekutor_options!(options)
        return true unless options.present?

        if (invalid_options = options.keys - VALID_EXEKUTOR_OPTIONS).present?
          raise InvalidOption, "Invalid option#{"s" if invalid_options.many?}: " \
            "#{invalid_options.map(&:inspect).join(", ")}. " \
            "Valid options are: #{VALID_EXEKUTOR_OPTIONS.map(&:inspect).join(", ")}"
        end
        if options[:queue_timeout] && !options[:queue_timeout].is_a?(ActiveSupport::Duration)
          raise InvalidOption, ":queue_timeout must be an instance of ActiveSupport::Duration"
        end
        if options[:execution_timeout] && !options[:execution_timeout].is_a?(ActiveSupport::Duration)
          raise InvalidOption, ":execution_timeout must be an instance of ActiveSupport::Duration"
        end

        true
      end
    end

    # Raised when invalid options are given
    class InvalidOption < ::Exekutor::Error; end
  end
end
