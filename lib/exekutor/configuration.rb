# frozen_string_literal: true

require_relative "internal/configuration_builder"

module Exekutor
  # Configuration for the Exekutor library
  class Configuration
    include Internal::ConfigurationBuilder

    # @private
    DEFAULT_BASE_RECORD_CLASS = "ActiveRecord::Base"
    private_constant "DEFAULT_BASE_RECORD_CLASS"

    # @!macro
    #   @!method $1
    #     Gets the default queue name. Is used when enqueueing jobs that don't have a queue set.
    #     === Default value:
    #     +"default"+
    #     @return [String]
    #   @!method $1=(value)
    #     Sets the default queue name. Is used when enqueueing jobs that don't have a queue set. The name should not be
    #     blank and should be shorter than 64 characters.
    #     @raise [Error] When the name is blank or too long
    #     @param value [String] the queue name
    #     @return [self]
    define_option :default_queue_name, default: "default", required: true, type: String do |value|
      if value.length > Exekutor::Queue::MAX_NAME_LENGTH
        raise Error, "The queue name \"#{value}\" is too long, the limit is #{Exekutor::Queue::MAX_NAME_LENGTH} characters"
      end
    end

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
    #     Gets the named priorities. These will be used when enqueueing a job which has a +Symbol+ as priority value.
    #     === Default value:
    #     None, using a +Symbol+ as priority raises an error by default.
    #     @return [Hash<Symbol, Integer>,nil]
    #   @!method $1=(value)
    #     Sets the named priorities. These will be used when enqueueing a job which has a +Symbol+ as priority value.
    #     Should be a Hash with +Symbol+ keys and +Integer+ values, the values should be between 1 and 32,767.
    #     @raise [Error] When the value contains invalid keys or values
    #     @param value [Hash<Symbol, Integer>,nil] the priorities
    #     @return [self]
    define_option :named_priorities, type: Hash do |value|
      if (invalid_keys = value.keys.select { |k| !k.is_a? Symbol }).present?
        class_names = invalid_keys.map(&:class).map(&:name).uniq
        raise Error, "Invalid priority name type#{"s" if class_names.many?}: #{class_names.join(", ")}"
      end
      if (invalid_values = value.values.select { |v| !(v.is_a?(Integer) && (Exekutor::Queue::VALID_PRIORITIES).include?(v)) }).present?
        raise Error, "Invalid priority value#{"s" if invalid_values.many?}: #{invalid_values.join(", ")}"
      end
    end

    # Gets the priority value for the given name
    # @param name [Symbol] the priority name
    # @return [Integer] the priority value
    def priority_for_name(name)
      if named_priorities.blank?
        raise Error, "You have configured '#{name}' as a priority, but #named_priorities is not configured"
      end
      raise Error, "The priority name should be a Symbol (actual: #{name.class})" unless name.is_a? Symbol
      raise Error, "#named_priorities does not contain a value for '#{name}'" unless named_priorities.include? name

      named_priorities[name]
    end

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
    define_option :base_record_class_name, default: DEFAULT_BASE_RECORD_CLASS, required: true,
                  type: String

    # Gets the base class for database records. Is derived from the {#base_record_class_name} option.
    # @raise [Error] when the class cannot be found
    # @return [Class]
    def base_record_class
      const_get :base_record_class_name
    rescue Error
      # A nicer message for the default value
      if base_record_class_name == DEFAULT_BASE_RECORD_CLASS
        raise Error, "Cannot find ActiveRecord, did you install and load the gem?"
      else
        raise
      end
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
    define_option :json_serializer, default: JSON, required: true do |value|
      unless value.is_a?(String) || value.is_a?(Symbol) || value.respond_to?(:call) ||
        (value.respond_to?(:dump) && value.respond_to?(:load))
        raise Error, "#json_serializer must either be a String, a Proc, or respond to #dump and #load"
      end
    end

    # Gets the JSON serializer. Is derived from the {#json_serializer} option.
    # @raise [Error] when the class cannot be found, or does not respond to +#dump+ and +#load+
    # @return [Object]
    def load_json_serializer
      raw_value = self.json_serializer
      return @json_serializer_instance[1] if @json_serializer_instance && @json_serializer_instance[0] == raw_value

      serializer = const_get :json_serializer
      unless serializer.respond_to?(:dump) && serializer.respond_to?(:load)
        if serializer.respond_to?(:call)
          serializer = serializer.call
        elsif serializer.respond_to?(:new)
          serializer = serializer.new
        end
      end
      unless serializer.respond_to?(:dump) && serializer.respond_to?(:load)
        raise Error, <<~MSG.squish
          The configured serializer (#{serializer.name}) does not respond to #dump and #load
        MSG
      end

      @json_serializer_instance = [raw_value, serializer]
      serializer
    end

    # @!macro
    #   @!method $1
    #     Gets the logger.
    #     === Default value:
    #       Rails.logger
    #     @return [ActiveSupport::Logger]
    #   @!method $1=(value)
    #     Sets the logger.
    #     @param value [ActiveSupport::Logger] the logger
    #     @return [self]
    define_option :logger, default: -> { Rails.logger } # TODO: better default?

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
    define_option :enable_listener, reader: :enable_listener?, default: true, type: [TrueClass, FalseClass], required: true

    # @!macro
    #   @!method $1
    #     The polling interval in seconds. When set, the worker will poll the database with this interval to check for
    #     any pending jobs that a listener might have missed (if enabled).
    #     === Default value:
    #     60
    #     @return [Integer]
    #   @!method $1=(value)
    #     Sets the polling interval in seconds. Set to +nil+ to disable polling. If the listener is disabled, this value
    #     should be reasonably low so jobs don't have to wait in the queue too long; if it is enabled, this value can
    #     be reasonably high.
    #     @param value [Integer] the interval
    #     @return [self]
    define_option :polling_interval, default: 60, type: [Integer, nil], range: 1...(1.day.to_i)

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
    #     greater than +connection_db_config.pool+, workers may have to wait for database connections to be available
    #     because all connections are occupied by other workers. This may result in a
    #     +ActiveRecord::ConnectionTimeoutError+ if the worker has to wait too long.
    #     @param value [Integer] the number of threads
    #     @return [self]
    define_option :max_execution_threads,
                  default: -> { (Exekutor::Job.connection_db_config.pool.to_i - 1).clamp(1, 999) },
                  type: Integer, range: 1...999

    # @!macro
    #   @!method $1
    #     The maximum number of seconds a thread may be idle before being stopped.
    #     === Default value:
    #     60
    #     @return [Integer]
    #   @!method $1=(value)
    #     Sets the maximum number of seconds a thread may be idle before being stopped
    #     @param value [Integer] the number of threads
    #     @return [self]
    define_option :max_execution_thread_idletime, default: 60, type: Integer, range: 1..(1.day.to_i)

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
      {}.tap do |opts|
        opts[:min_threads] = min_execution_threads
        opts[:max_threads] = max_execution_threads
        opts[:max_thread_idletime] = max_execution_thread_idletime
        opts[:set_db_connection_name] = set_db_connection_name? unless set_db_connection_name.nil?
        opts[:enable_listener] = !!enable_listener?
        %i(polling_interval polling_jitter).each do |option|
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
        rescue NameError
          raise Error, <<~MSG.squish
            Cannot convert ##{parameter_name} (#{class_name.inspect}) to a constant. Have you made a typo?
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
  end

  def self.config
    @config ||= Exekutor::Configuration.new
  end

  def self.configure(opts = nil, &block)
    raise ArgumentError, "opts must be a Hash" unless opts.nil? || opts.is_a?(Hash)
    raise ArgumentError, "Either opts or a block must be given" unless opts.present? || block_given?
    config.set **opts if opts
    if block_given?
      if block.arity == 1
        block.call config
      else
        instance_eval &block
      end
    end
  end
end