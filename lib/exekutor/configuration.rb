# frozen_string_literal: true

require_relative "internal/configuration_builder"
module Exekutor
  class Configuration
    include Internal::ConfigurationBuilder

    # Valid range for job priority
    # @private
    VALID_PRIORITIES = 1..32_767
    private_constant "VALID_PRIORITIES"

    # @private
    DEFAULT_BASE_RECORD_CLASS = "ActiveRecord::Base"
    private_constant "DEFAULT_BASE_RECORD_CLASS"

    # @!method $1
    #   Gets the default queue name to use when enqueueing jobs. (Default value: "default")
    #   @return String
    # @!method $1=(value)
    #   Sets the default queue name to use when enqueueing jobs.
    #   @param [String] value the queue name
    define_option :default_queue_name, default: "default", nullable: false, allowed_types: String

    # @!method $1
    #   Gets the default queue priority to use when enqueueing jobs. (Default value: 16_383)
    #   @return [Integer]
    # @!method $1=(value)
    #   Sets the default queue priority to use when enqueueing jobs. Should be between 1 and 32,767.
    #   @param [Integer] value the queue priority
    define_option :default_queue_priority, default: 16_383, nullable: false, allowed_types: Integer, range: VALID_PRIORITIES

    # @!method $1
    #   Gets the name of the base class for database records. (Default value: "ActiveRecord::Base")
    #   @return [String]
    # @!method $1=(value)
    #   Sets the name of the base class for database records.
    #   @param [String] value the class name
    define_option :base_record_class_name, default: DEFAULT_BASE_RECORD_CLASS, nullable: false, allowed_types: String

    # Gets the class for the +BaseRecord+
    # @return [Class]
    def base_record_class
      const_get :base_record_class_name, self.base_record_class_name
    rescue Error
      # A nicer message for the default value
      if self.base_record_class_name == DEFAULT_BASE_RECORD_CLASS
        raise Error, "Cannot find ActiveRecord, did you install and load the gem?"
      else
        raise
      end
    end

    # TODO semantics

    # @!method $1
    #   Gets the raw value of the JSON serializer setting, this can be either a String or the serializer.
    #   (Default value: +JSON+)
    #   @return A String or a serializer responding to #dump and #load
    # @!method $1=(value)
    #   Sets the JSON serializer. This can be either a +String+, +Proc+, or the serializer, which must respond to #dump
    #   and #load. If a +String+ or +Proc+ is given, the class will be loaded when $1 is called. If the loaded class
    #   does not respond to #dump and #load a +Exekutor::Configuration::Error+ whenever the serializer is used for the
    #   first time. If the value is neither a +String+ nor a +Proc+ and does not respond to #dump and #load, the error
    #   will be thrown immediately.
    #   @param value The serializer
    define_option :json_serializer, default: JSON, nullable: false do |value|
      unless value.is_a?(String) || value.respond_to?(:call) || (value.respond_to?(:dump) && value.respond_to?(:load))
        raise Error, "#json_serializer must either be a string or respond to #dump and #load"
      end
    end

    def json_serializer_instance
      raw_value = self.json_serializer
      return @json_serializer_class[1] if @json_serializer_class && @json_serializer_class[0] == raw_value

      serializer = const_get :json_serializer, raw_value
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

      @json_serializer_class = [raw_value, serializer]
      serializer
    end

    # @!method $1
    #   Gets the logger to use. (Default value: `Rails.logger`)
    #   @return [ActiveSupport::Logger]
    # @!method $1=(value)
    #   Sets the logger to use
    #   @param [ActiveSupport::Logger] value the logger
    define_option :logger, default: -> { Rails.logger } # TODO better default

    # @!method $1
    #   Gets the named priorities. These will be used when enqueueing a job which has a symbol as priority value.
    #   (Default value: none)
    #   @return [Hash]
    # @!method $1=(value)
    #   Sets the named priorities
    #   @param [Hash<Symbol, Integer>] value the priorities. Keys must be symbols and values must be valid priorities.
    define_option :named_priorities, allowed_types: Hash do |value|
      if (invalid_keys = value.keys.select { |k| !k.is_a? Symbol }).present?
        class_names = invalid_keys.map(&:class).map(&:name).uniq
        raise Error, "Invalid priority name type#{"s" if class_names.many?}: #{class_names.join(", ")}"
      end
      if (invalid_values = value.values.select { |v| !(v.is_a?(Integer) && (VALID_PRIORITIES).include?(v)) }).present?
        raise Error, "Invalid priority value#{"s" if invalid_values.many?}: #{invalid_values.join(", ")}"
      end
    end

    def priority_for_name(name)
      if named_priorities.blank?
        raise Error, "You have configured '#{name}' as a priority, but #named_priorities is not configured"
      end
      raise Error, "#named_priorities does not contain a value for '#{name}'" unless named_priorities.include? name
      named_priorities[name]
    end

    def verbose?
      true
    end

    def worker_options
      {}
    end

    private

    def const_get(parameter_name, parameter_value)
      case parameter_value
      when String, Symbol
        begin
          class_name = if parameter_value.is_a? Symbol
                         parameter_value.to_s.camelize.prepend("::")
                       elsif parameter_value.start_with? "::"
                         parameter_value
                       else
                         parameter_value.dup.prepend("::")
                       end

          Object.const_get class_name
        rescue NameError
          raise Error, <<~MSG.squish
            Cannot convert ##{parameter_name} (#{parameter_value.inspect}) to a constant. Have you made a typo?
          MSG
        end
      else
        parameter_value
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