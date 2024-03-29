# frozen_string_literal: true

module Exekutor
  module Internal
    # DSL for the configuration
    # @private
    module ConfigurationBuilder
      extend ActiveSupport::Concern

      included do
        class_attribute :__option_names, instance_writer: false, default: []
      end

      # Indicates an unset value
      # @private
      DEFAULT_VALUE = Object.new.freeze
      private_constant :DEFAULT_VALUE

      # Sets option values in bulk
      # @return [self]
      def set(**options)
        invalid_options = options.keys - __option_names
        if invalid_options.present?
          raise error_class, "Invalid option#{"s" if invalid_options.many?}: #{
            invalid_options.map(&:inspect).join(", ")}"
        end

        options.each do |name, value|
          send :"#{name}=", value
        end
        self
      end

      class_methods do # rubocop:disable Metrics/BlockLength
        # Defines a configuration option with the given name.
        # @param name [Symbol] the name of the option
        # @param required [Boolean] whether a value is required. If +true+, any +nil+ or +blank?+ value will not be
        #   allowed.
        # @param type [Class,Array<Class>] the allowed value types. If set the value must be an instance of any of the
        #   given classes.
        # @param enum [Array<Any>] the allowed values. If set the value must be one of the given values.
        # @param range [Range] the allowed value range. If set the value must be included in this range.
        # @param default [Any] the default value
        # @param reader [Symbol] the name of the reader method
        # rubocop:disable Metrics/ParameterLists
        def define_option(name, required: false, type: nil, enum: nil, range: nil, default: DEFAULT_VALUE,
                          reader: name, &block)
          # rubocop:enable Metrics/ParameterLists
          __option_names << name
          define_reader(reader, name, default) if reader
          define_writer(name, required, type, enum, range, &block)
        end

        private

        def define_writer(name, required, type, enum, range)
          define_method :"#{name}=" do |value|
            validate_option_presence! name, value if required
            validate_option_type! name, value, *type if type.present?
            validate_option_enum! name, value, *enum if enum.present?
            validate_option_range! name, value, range if range.present?
            yield value if block_given?

            instance_variable_set :"@#{name}", value
            self
          end
        end

        def define_reader(name, variable_name, default)
          define_method name do
            if instance_variable_defined? :"@#{variable_name}"
              instance_variable_get :"@#{variable_name}"
            elsif default.respond_to? :call
              default.call
            elsif default != DEFAULT_VALUE
              default
            end
          end
        end
      end

      # Validates whether the option is present for configuration values that are required
      # raise [StandardError] if the value is nil or blank
      def validate_option_presence!(name, value)
        return if value.present? || value.is_a?(FalseClass)

        raise error_class, "##{name} cannot be #{value.nil? ? "nil" : "blank"}"
      end

      # Validates whether the value class is allowed
      # @raise [StandardError] if the type of value is not allowed
      def validate_option_type!(name, value, *allowed_types)
        return if allowed_types.include?(value.class)

        raise error_class, "##{name} should be an instance of #{
          allowed_types.map { |c| c == NilClass || c.nil? ? "nil" : c }
                       .to_sentence(two_words_connector: " or ", last_word_connector: ", or ")
        } (Actual: #{value.class})"
      end

      # Validates whether the value is a valid enum option
      # @raise [StandardError] if the value is not included in the allowed values
      def validate_option_enum!(name, value, *allowed_values)
        return if allowed_values.include?(value)

        raise error_class, "##{name} should be one of #{
          allowed_values.map(&:inspect)
                        .to_sentence(two_words_connector: " or ", last_word_connector: ", or ")
        }"
      end

      # Validates whether the value falls in the allowed range
      # @raise [StandardError] if the value is not included in the allowed range
      def validate_option_range!(name, value, allowed_range)
        return if allowed_range.include?(value)

        raise error_class, <<~MSG
            ##{name} should be between #{allowed_range.first.inspect} and #{allowed_range.last.inspect}#{
          " (exclusive)" if allowed_range.respond_to?(:exclude_end?) && allowed_range.exclude_end?}
        MSG
      end

      protected

      # The error class to raise when an invalid option value is set
      # @return [Class<StandardError>]
      def error_class
        raise NotImplementedError, "Implementing class should override #error_class"
      end
    end
  end
end
