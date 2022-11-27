module Exekutor
  module JobOptions
    extend ActiveSupport::Concern

    VALID_EXEKUTOR_OPTIONS = %i[maximum_queue_duration execution_timeout]

    attr_reader :exekutor_options

    def enqueue(options = {})
      @exekutor_options = self.class.exekutor_job_options || {}
      job_options = options&.slice *VALID_EXEKUTOR_OPTIONS
      if job_options
        self.class.validate_exekutor_options! job_options
        @exekutor_options = @exekutor_options.merge job_options
      end
      super(options)
    end

    module ClassMethods
      def exekutor_options(options)
        validate_exekutor_options! options
        @exekutor_job_options = options
      end

      def exekutor_job_options
        @exekutor_job_options
      end

      def validate_exekutor_options!(options)
        return unless options.present?
        invalid_options = options.keys - VALID_EXEKUTOR_OPTIONS
        if invalid_options.present?
          raise Error, "Invalid option#{"s" if invalid_options.many?}: #{invalid_options.map(&:inspect).join(", ")}. " +
            "Valid options are: #{VALID_EXEKUTOR_OPTIONS.map(&:inspect).join(", ")}"
        end
        if options[:maximum_queue_duration]
          raise Error, ":maximum_queue_duration must be an interval" unless options[:maximum_queue_duration].is_a? ActiveSupport::Duration
        end
        if options[:execution_timeout]
          raise Error, ":execution_timeout must be an interval" unless options[:execution_timeout].is_a? ActiveSupport::Duration
        end
      end
    end

    class Error < ::Exekutor::Error; end
  end
end