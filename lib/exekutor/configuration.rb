# frozen_string_literal: true

module Exekutor
  class Configuration
    DEFAULT_QUEUE_NAME = "default"
    DEFAULT_QUEUE_PRIORITY = 16_383
    DEFAULT_LOGGER = Object.new

    # TODO guard clauses for writers so we don't need to validate every read
    # TODO implement #worker_options

    attr_accessor :job_base_class_name, :json_serializer, :logger, :default_queue_name, :default_queue_priority,
                  :named_priorities

    def initialize
      # Defaults
      @job_base_class_name = "ActiveRecord::Base"
      @json_serializer = JSON
      @logger = DEFAULT_LOGGER
      @default_queue_name = DEFAULT_QUEUE_NAME
      @default_queue_priority = DEFAULT_QUEUE_PRIORITY
    end

    def job_base_class
      raise Error, "#job_base_class_name is not configured" if job_base_class_name.blank?

      const_get :job_base_class_name, job_base_class_name
    rescue Error
      # A nicer message for the default value
      if job_base_class_name == "ActiveRecord::Base"
        raise Error, "Cannot find ActiveRecord, did you install and load the gem?"
      else
        raise
      end
    end

    def json_serializer_class
      return @json_serializer_class[1] if @json_serializer_class && @json_serializer_class[0] == json_serializer
      raise Error, "#json_serializer is not configured" if json_serializer.blank?

      serializer = const_get :json_serializer, json_serializer
      unless serializer.respond_to?(:dump) && serializer.respond_to?(:load)
        raise Error, <<~MSG.squish
          The configured serializer (#{serializer.name}) does not respond to #dump and #load
        MSG
      end

      @json_serializer_class = [json_serializer, serializer]
      serializer
    end

    def priority_for_name(name)
      if named_priorities.blank?
        raise Error, "You have configured '#{name}' as a priority, but #named_priorities is not configured"
      end
      raise Error, "#named_priorities must be a hash" unless named_priorities.is_a? Hash

      priority = named_priorities[name]
      raise Error, "#named_priorities does not contain a value for '#{name}'" if priority.nil?
      unless priority.is_a? Integer
        raise Error, "#named_priorities contains an invalid value for '#{name}' (#{priority.class})"
      end

      priority
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

    class Error < StandardError; end

  end
end