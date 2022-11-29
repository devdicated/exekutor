# frozen_string_literal: true

module Exekutor
  module Internal
    # DSL for the configuration
    # @private
    module ConfigurationBuilder
      extend ActiveSupport::Concern

      # Indicates an unset value
      # @private
      DEFAULT_VALUE = Object.new.freeze
      private_constant "DEFAULT_VALUE"

      # Contains class methods to define on classes including this builder
      module ClassMethods
        def define_option(name, required: false, allowed_types: nil, enum: nil, range: nil, default: DEFAULT_VALUE)
          define_method name do
            if instance_variable_defined? :"@#{name}"
              instance_variable_get :"@#{name}"
            elsif default.respond_to? :call
              default.call
            else
              default
            end
          end

          define_method "#{name}=" do |value|
            validate_option_presence! name, value if required
            validate_option_type! name, value, *allowed_types if allowed_types.present?
            validate_option_enum! name, value, *enum if enum.present?
            validate_option_range! name, value, range if range.present?
            yield value if block_given?

            instance_variable_set :"@#{name}", value
            self
          end
        end
      end

      def validate_option_presence!(name, value)
        raise error_class, "##{name} cannot be #{value.nil? ? "nil" : "blank"}" unless value.present?
      end

      def validate_option_type!(name, value, *allowed_types)
        return if allowed_types.include?(value.class)

        raise error_class, "##{name} should be an instance of #{allowed_types.to_sentence(last_word_connector: ', or ')} (Actual: #{value.class})"
      end

      def validate_option_enum!(name, value, *allowed_values)
        return if allowed_values.include?(value)

        raise error_class, "##{name} should be one of #{allowed_values.map(&:inspect).to_sentence(last_word_connector: ', or ')}"
      end

      def validate_option_range!(name, value, allowed_range)
        return if allowed_range.include?(value)

        raise error_class, "##{name} should be between #{allowed_range.first} and #{allowed_range.last}#{
          if allowed_range.respond_to?(:exclude_end?) && allowed_range.exclude_end?
            " (exclusive)"
          end}"
      end

      protected

      def error_class
        raise "Implementing class should override #error_class"
      end
    end
  end
end