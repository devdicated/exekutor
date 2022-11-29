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
    define_option :default_queue_name, default: "default", required: true, allowed_types: String do |value|
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
    define_option :default_queue_priority, default: 16_383, required: true, allowed_types: Integer,
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
    define_option :named_priorities, allowed_types: Hash do |value|
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
                  allowed_types: String

    # Gets the base class for database records. Is derived from the {#base_record_class_name} option.
    # @raise [Error] when the class cannot be found
    # @return [Class]
    def base_record_class
      puts "base_record_class_name: #{base_record_class_name}"
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
    define_option :logger, default: -> { Rails.logger } # TODO: better default

    def verbose?
      true
    end

    def worker_options
      {}
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

    # Error thrown for invalid configuration options
    class Error < StandardError; end

    protected

    def error_class
      Error
    end
  end

  def self.config
    @config ||= Exekutor::Configuration.new
  end
end