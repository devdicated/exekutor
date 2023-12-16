# frozen_string_literal: true

require_relative "internal/configuration_builder"

# The Exekutor namespace
module Exekutor
  # Configuration for the Exekutor library
  class Configuration
    include Internal::ConfigurationBuilder

    # @private
    DEFAULT_BASE_RECORD_CLASS = "ActiveRecord::Base"
    private_constant :DEFAULT_BASE_RECORD_CLASS

    # @!macro
    #   @!method $1
    #     Gets the default queue priority. Is used when enqueueing jobs that don't have a priority set.
    #     === Default value:
    #     16,383
    #     @return [Integer]
    #   @!method $1=(value)
    #     Sets the default queue priority. Is used when enqueueing jobs that don't have a priority set. Should be
    #     between 1 and 32,767.
    #     @raise [Error] When the priority is nil or invalid
    #     @param value [Integer] the priority
    #     @return [self]
    define_option :default_queue_priority, default: 16_383, required: true, type: Integer,
                  range: Exekutor::Queue::VALID_PRIORITIES

    # @!macro
    #   @!method $1
    #     Gets the base class name for database records.
    #     === Default value:
    #     +"ActiveRecord::Base"+
    #     @return [String]
    #   @!method $1=(value)
    #     Sets the base class name for database records. The validity of this value will not be checked immediately.
    #     (Ie. When the specified class does not exist, an error will raised when a database record is used for the
    #     first time.)
    #     @raise [Error] When the name is blank
    #     @param value [String] the class name
    #     @return [self]
    define_option :base_record_class_name, default: DEFAULT_BASE_RECORD_CLASS, required: true, type: String

    # Gets the base class for database records. Is derived from the {#base_record_class_name} option.
    # @raise [Error] when the class cannot be found
    # @return [Class]
    def base_record_class
      const_get :base_record_class_name
    rescue ::StandardError
      # A nicer message for the default value
      if base_record_class_name == DEFAULT_BASE_RECORD_CLASS
        raise Error, "Cannot find ActiveRecord, did you install and load the gem?"
      end

      raise
    end

    # @!macro
    #   @!method $1
    #     Gets the unconverted JSON serializer value. This can be either a +String+, a +Symbol+, a +Proc+, or the
    #     serializer.
    #     === Default value:
    #     +JSON+
    #     @return [String,Symbol,Proc,Object]
    #   @!method $1=(value)
    #     Sets the JSON serializer. This can be either a +String+, a +Symbol+, a +Proc+, or the serializer. If a
    #     +String+, +Symbol+, or +Proc+ is given, the serializer will be loaded when it is needed for the first time.
    #     If the loaded class does not respond to +#dump+ and +#load+ an {Error} will be raised whenever the serializer
    #     is loaded. If the value is neither a +String+, +Symbol+, nor a +Proc+ and it does not respond to +#dump+ and
    #     +#load+, the error will be thrown immediately.
    #     @raise [Error] When the value is neither a +String+, +Symbol+, nor a +Proc+ and it does not respond to +#dump+
    #                    and +#load+
    #     @param value [String,Symbol,Proc,Object] the serializer
    #     @return [self]
    define_option :json_serializer, default: "::JSON", required: true do |value|
      unless value.is_a?(String) || value.is_a?(Symbol) || value.respond_to?(:call) || SerializerValidator.valid?(value)
        raise Error, "#json_serializer must either be a String, a Proc, or respond to #dump and #load"
      end
    end

    # Gets the JSON serializer. Is derived from the {#json_serializer} option.
    # @raise [Error] when the class cannot be found, or does not respond to +#dump+ and +#load+
    # @return [Object]
    def load_json_serializer
      raw_value = json_serializer
      if defined?(@json_serializer_instance) && @json_serializer_instance[0] == raw_value
        return @json_serializer_instance[1]
      end

      serializer = const_get :json_serializer
      serializer = SerializerValidator.convert! serializer unless SerializerValidator.valid? serializer
      @json_serializer_instance = [raw_value, serializer]
      serializer
    end

    # @!macro
    #   @!method $1
    #     Gets the logger.
    #     === Default value:
    #       Rails.active_job.logger
    #     @return [ActiveSupport::Logger]
    #   @!method $1=(value)
    #     Sets the logger.
    #     @param value [ActiveSupport::Logger] the logger
    #     @return [self]
    define_option :logger, default: -> { Rails.active_job.logger }

    # @!macro
    #   @!method $1?
    #     Whether the DB connection name should be set. Only affects the listener, unless started from the CLI.
    #     === Default value:
    #     false (true when started from the CLI)
    #     @return [Boolean, nil]
    #   @!method $1=(value)
    #     Sets whether the DB connection name should be set
    #     @param value [Boolean] whether to name should be set
    #     @return [self]
    define_option :set_db_connection_name, type: [TrueClass, FalseClass], required: true

    def set_db_connection_name?
      if set_db_connection_name.nil?
        false
      else
        set_db_connection_name
      end
    end

    # @!macro
    #   @!method $1?
    #     Whether the worker should use LISTEN/NOTIFY to listen for jobs.
    #     === Default value:
    #     true
    #     @return [Boolean, nil]
    #   @!method $1=(value)
    #     Sets whether the worker should use LISTEN/NOTIFY to listen for jobs
    #     @param value [Boolean] whether to enable the listener
    #     @return [self]
    define_option :enable_listener, reader: :enable_listener?, default: true, type: [TrueClass, FalseClass],
                  required: true

    # @!macro
    #   @!method $1?
    #     Whether the worker should delete jobs after completion.
    #     === Default value:
    #     false
    #     @return [Boolean]
    #   @!method $1=(value)
    #     Sets whether the worker should delete jobs after completion
    #     @param value [Boolean] whether to delete completed jobs
    #     @return [self]
    define_option :delete_completed_jobs, reader: :delete_completed_jobs?, required: true,
                  type: [TrueClass, FalseClass], default: false

    # @!macro
    #   @!method $1?
    #     Whether the worker should delete discarded jobs.
    #     === Default value:
    #     false
    #     @return [Boolean]
    #   @!method $1=(value)
    #     Sets whether the worker should delete discarded jobs
    #     @param value [Boolean] whether to delete discarded jobs
    #     @return [self]
    define_option :delete_discarded_jobs, reader: :delete_discarded_jobs?, required: true,
                  type: [TrueClass, FalseClass], default: false

    # @!macro
    #   @!method $1?
    #     Whether the worker should delete jobs after they failed to execute.
    #     === Default value:
    #     false
    #     @return [Boolean]
    #   @!method $1=(value)
    #     Sets whether the worker should delete jobs after they failed to execute
    #     @param value [Boolean] whether to delete failed jobs
    #     @return [self]
    define_option :delete_failed_jobs, reader: :delete_failed_jobs?, required: true,
                  type: [TrueClass, FalseClass], default: false

    # @!macro
    #   @!method $1
    #     The polling interval. When set, the worker will poll the database with this interval to check for
    #     any pending jobs that a listener might have missed (if enabled).
    #     === Default value:
    #     60 seconds
    #     @return [ActiveSupport::Duration]
    #   @!method $1=(value)
    #     Sets the polling interval. Set to +nil+ to disable polling. If the listener is disabled, this value
    #     should be reasonably low so jobs don't have to wait in the queue too long; if the listener is enabled, this
    #     value can be reasonably high.
    #     @param value [ActiveSupport::Duration] the interval
    #     @return [self]
    define_option :polling_interval, default: 1.minute, type: [ActiveSupport::Duration, nil],
                  range: (1.second)...(1.day)

    # @!macro
    #   @!method $1
    #     The polling jitter, used to adjust the polling interval slightly so multiple workers will not query the
    #     database at the same time.
    #     === Default value:
    #     0.1
    #     @return [Float]
    #   @!method $1=(value)
    #     Sets the polling jitter, which is used to slightly adjust the polling interval. Should be between 0 and 0.5.
    #     A value of 0.1 means the polling interval can vary by 10%. If the interval is set to 60 seconds and the jitter
    #     is set to 0.1, the interval can range from 57 to 63 seconds. A value of 0 disables this feature.
    #     @param value [Float] the jitter
    #     @return [self]
    define_option :polling_jitter, default: 0.1, type: [Float, Integer], range: 0..0.5

    # @!macro
    #   @!method $1
    #     The minimum number of execution threads that should be active.
    #     === Default value:
    #     1
    #     @return [Integer]
    #   @!method $1=(value)
    #     Sets the minimum number of execution threads that should be active
    #     @param value [Integer] the number of threads
    #     @return [self]
    define_option :min_execution_threads, default: 1, type: Integer, range: 1...999

    # @!macro
    #   @!method $1
    #     The maximum number of execution threads that may be active.
    #     === Default value:
    #     Active record pool size minus 1, with a minimum of 1
    #     @return [Integer]
    #   @!method $1=(value)
    #     Sets the maximum number of execution threads that may be active. Be aware that if you set this to a value
    #     greater than +connection_db_config.pool+, workers may have to wait for database connections to become
    #     available because all connections are occupied by other threads. This may result in an
    #     +ActiveRecord::ConnectionTimeoutError+ if the thread has to wait too long.
    #     @param value [Integer] the number of threads
    #     @return [self]
    define_option :max_execution_threads,
                  default: -> { (Internal::BaseRecord.connection_db_config.pool.to_i - 1).clamp(1, 999) },
                  type: Integer, range: 1...999

    # @!macro
    #   @!method $1
    #     The maximum duration a thread may be idle before being stopped.
    #     === Default value:
    #     60 seconds
    #     @return [ActiveSupport::Duration]
    #   @!method $1=(value)
    #     Sets the maximum duration a thread may be idle before being stopped
    #     @param value [ActiveSupport::Duration] the number of threads
    #     @return [self]
    define_option :max_execution_thread_idletime, default: 1.minute, type: ActiveSupport::Duration,
                  range: (1.second)..(1.day)

    # @!macro
    #   @!method $1?
    #     The rack handler for the status server
    #     === Default value:
    #     +"webrick"+
    #     @return [String]
    #   @!method $1=(value)
    #     Sets the rack handler for the status server. The handler should respond to +#shutdown+ or +#stop+.
    #     @param value [String] the name of the handler
    #     @return [self]
    define_option :status_server_handler, default: "webrick", type: String

    # @!macro
    #   @!method $1?
    #     The port number for the status server
    #     === Default value:
    #     +nil+ (ie. the status server is disabled)
    #     @return [Integer]
    #   @!method $1=(value)
    #     Sets the port number for the status server.
    #     @param value [Integer] the port number
    #     @return [self]
    define_option :status_server_port, default: nil, type: Integer

    # @!macro
    #   @!method $1?
    #     The heartbeat timeout for the `/live` endpoint of the status server. If the heartbeat of a worker
    #     is older than this timeout, the status server will respond with a 503 status indicating the service is
    #     down.
    #     === Default value:
    #     30 minutes
    #     @return [ActiveSupport::Duration]
    #   @!method $1=(value)
    #     Sets the heartbeat timeout for the `/live` endpoint of the status server. Must be between 1 minute
    #     and 24 hours.
    #     @param value [ActiveSupport::Duration] The timeout in minutes
    #     @return [self]
    define_option :healthcheck_timeout, default: 30.minutes, type: ActiveSupport::Duration,
                  range: (1.minute)..(1.day)

    # @!macro
    #   @!method $1?
    #     Whether to suppress STDOUT messages
    #     === Default value:
    #     false
    #     @return [Boolean]
    #   @!method $1=(value)
    #     Sets whether the STDOUT messages should be printed
    #     @param value [Boolean] whether to suppress STDOUT messages
    #     @return [self]
    define_option :quiet, reader: :quiet?, type: [TrueClass, FalseClass], required: true, default: false

    # Gets the options for a worker
    # @return [Hash] the worker configuration
    def worker_options
      {
        min_threads: min_execution_threads,
        max_threads: max_execution_threads,
        max_thread_idletime: max_execution_thread_idletime.to_f
      }.tap do |opts|
        opts[:set_db_connection_name] = set_db_connection_name? unless set_db_connection_name.nil?
        %i[enable_listener delete_completed_jobs delete_discarded_jobs delete_failed_jobs].each do |option|
          opts[option] = send(:"#{option}?") ? true : false
        end
        %i[polling_interval polling_jitter status_server_handler status_server_port healthcheck_timeout]
          .each do |option|
          opts[option] = send(option)
        end
      end
    end

    private

    def const_get(option_name)
      class_name = send(option_name)
      case class_name
      when String, Symbol
        begin
          class_name = if class_name.is_a? Symbol
                         class_name.to_s.camelize.prepend("::")
                       elsif class_name.start_with? "::"
                         class_name
                       else
                         class_name.dup.prepend("::")
                       end

          Object.const_get class_name
        rescue NameError, LoadError
          raise Error, <<~MSG.squish
            Cannot convert ##{option_name} (#{class_name.inspect}) to a constant. Have you made a typo?
          MSG
        end
      else
        class_name
      end
    end

    # Raised when configuring an invalid option or value
    class Error < Exekutor::Error; end

    protected

    def error_class
      Error
    end

    # Validates the value for a serializer, which must implement dump & load
    class SerializerValidator
      # @param serializer [Any] the value to validate
      # @return [Boolean] whether the serializer has implemented dump & load
      def self.valid?(serializer)
        serializer.respond_to?(:dump) && serializer.respond_to?(:load)
      end

      # Tries to convert the specified value to a serializer, raises an error if the conversion fails.
      # @param serializer [Any] the value to convert
      # @return [#dump&#load]
      # @raise [Error] if the serializer has not implemented dump & load
      def self.convert!(serializer)
        return serializer if SerializerValidator.valid? serializer

        if serializer.respond_to?(:call)
          serializer = serializer.call
          return serializer if SerializerValidator.valid? serializer
        end
        if serializer.respond_to?(:new)
          serializer = serializer.new
          return serializer if SerializerValidator.valid? serializer
        end

        raise Error, <<~MSG.squish
          The configured serializer (#{serializer.class}) does not respond to #dump and #load
        MSG
      end
    end
  end

  def self.config
    @config ||= Exekutor::Configuration.new
  end

  def self.configure(opts = nil, &block)
    raise ArgumentError, "either opts or a block must be given" unless opts || block

    if opts
      raise ArgumentError, "opts must be a Hash" unless opts.is_a?(Hash)

      config.set(**opts)
    end
    if block
      if block.arity.zero?
        instance_eval(&block)
      else
        yield config
      end
    end
    self
  end
end
