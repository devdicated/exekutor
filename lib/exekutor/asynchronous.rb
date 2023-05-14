# frozen_string_literal: true

module Exekutor
  # Mixin to let methods be executed asynchronously by active job
  #
  # @example Mark methods as asynchronous
  #    class MyClass
  #      include Exekutor::Asynchronous
  #
  #      def instance_method
  #        puts "This will be performed by an Exekutor worker"
  #      end
  #      perform_asynchronously :instance_method
  #
  #      def self.class_method(str)
  #        puts "This will also be performed by an Exekutor worker: #{str}"
  #      end
  #      perform_asynchronously :class_method, class_method: true
  #    end
  module Asynchronous
    extend ActiveSupport::Concern

    included do
      mattr_reader :__async_class_methods, instance_accessor: false, default: {}
      mattr_reader :__async_instance_methods, instance_accessor: false, default: {}
      private_class_method :perform_asynchronously, :async_delegate_and_definitions, :redefine_method
    end

    class_methods do # rubocop:disable Metrics/BlockLength
      # Changes a method to be executed asynchronously.
      # Be aware that you can no longer use the return value for
      # asynchronous methods, because the actual method will be performed by a worker at a later time. The new
      # implementation of the method will always return an instance of {AsyncMethodJob}.
      # If the method takes parameters they must be serializable by active job, otherwise an
      # +ActiveJob::SerializationError+ will be raised.
      # @param method_name [Symbol] the method to be executed asynchronous
      # @param alias_to [String] specifies the new name for the synchronous method
      # @param class_method [Boolean] whether the method is a class method.
      # @raise [Error] if the method could not be replaced with the asynchronous version
      def perform_asynchronously(method_name, alias_to: "__immediately_#{method_name}", class_method: false)
        unless method_name.is_a? Symbol
          raise ArgumentError, "method_name must be a Symbol (actual: #{method_name.class.name})"
        end
        raise ArgumentError, "alias_to must be present" if alias_to.blank?

        delegate, definitions = async_delegate_and_definitions(method_name, class_method: class_method)
        raise Error, "##{method_name} was already marked as asynchronous" if definitions.include? method_name

        redefine_method_as_async(delegate, method_name, alias_to)
        definitions[method_name] = alias_to
        nil
      end

      # Gets the object to define aliased method on, and the definitions that are already defined
      # @return [Array(Any, Hash<Symbol=>Symbol>)] The delegate and the existing definitions
      def async_delegate_and_definitions(method_name, class_method:)
        if class_method
          raise ArgumentError, "##{method_name} does not exist" unless respond_to? method_name, true

          [singleton_class, __async_class_methods]
        else
          unless method_defined?(method_name, true) || private_method_defined?(method_name, true)
            raise ArgumentError, "##{method_name} does not exist"
          end

          [self, __async_instance_methods]
        end
      end

      # Aliases the indicated method and redefines the method to call the original method asynchronously.
      # @param delegate [Any] the delegate to redefine the method on
      # @param method_name [Symbol] the name of the method to redefine
      # @param alias_to [String] the name to alias the original method to
      # @return [Void]
      def redefine_method_as_async(delegate, method_name, alias_to)
        visibility = if delegate.private_method_defined?(method_name)
                       :private
                     elsif delegate.protected_method_defined?(method_name)
                       :protected
                     else
                       :public
                     end

        delegate.alias_method alias_to, method_name
        delegate.define_method method_name do |*args, **kwargs|
          error = Asynchronous.validate_args(self, alias_to, *args, **kwargs)
          raise error if error
          raise ArgumentError, "Cannot asynchronously execute with a block argument" if block_given?

          AsyncMethodJob.perform_later self, method_name, [args, kwargs.presence]
        end

        delegate.send(visibility, method_name)
      end
    end

    # Validates whether the given arguments match the expected parameters for +method+
    # @param delegate [Object] the object the +method+ will be called on
    # @param method [Symbol] the method that will be called on +delegate+
    # @param args [Array] the arguments that will be given to the method
    # @param kwargs [Hash] the keyword arguments that will be given to the method
    # @return [ArgumentError,nil] nil if the keywords are valid; an ArgumentError otherwise
    def self.validate_args(delegate, method, *args, **kwargs)
      error = ArgumentValidator.new(delegate, method).validate(args, kwargs)
      return nil unless error

      ArgumentError.new(error)
    end

    # The internal job used for {Exekutor::Asynchronous}. Only works for methods that are marked as asynchronous to
    # prevent remote code execution. Include the {Exekutor::Asynchronous} and call
    # +perform_asynchronously+ to mark a method as asynchronous.
    class AsyncMethodJob < ActiveJob::Base # rubocop:disable Rails/ApplicationJob
      # Calls the original, synchronous method
      # @!visibility private
      def perform(object, method, args)
        check_object! object
        method_alias = check_method! object, method
        args, kwargs = args
        if kwargs
          object.__send__(method_alias, *args, **kwargs)
        else
          object.__send__(method_alias, *args)
        end
      end

      private

      def check_object!(object)
        if object.nil?
          raise Error, "Object cannot be nil"
        elsif object.is_a? Class
          unless object.included_modules.include? Asynchronous
            raise Error, "Object has not included Exekutor::Asynchronous"
          end
        else
          raise Error, "Object has not included Exekutor::Asynchronous" unless object.is_a? Asynchronous
        end
      end

      def check_method!(object, method)
        if object.is_a? Class
          class_name = object.name
          definitions = object.__async_class_methods
        else
          class_name = object.class.name
          definitions = object.class.__async_instance_methods
        end
        raise Error, "#{class_name} does not respond to #{method}" unless object.respond_to? method, true
        raise Error, "#{class_name}##{method} is not marked as asynchronous" unless definitions.include? method.to_sym

        definitions[method.to_sym]
      end
    end

    # Validates whether a set of arguments is valid for a particular method
    class ArgumentValidator
      def initialize(delegate, method)
        @required_keywords = []
        @optional_keywords = []
        @accepts_keyrest = false
        parse_method_params delegate.method(method)
      end

      def parse_method_params(method)
        arguments = ArgumentCounter.new
        method.parameters.each do |type, name|
          case type
          when :req, :opt
            arguments.increment(type)
          when :rest
            arguments.clear_max
          when :keyreq
            @required_keywords << name
          when :key
            @optional_keywords << name
          when :keyrest
            @accepts_keyrest = true
          else
            Exekutor.say "Unsupported parameter type: #{type.inspect}"
          end
        end
        @arg_length = arguments.to_range
      end

      def accepts_keywords?
        @accepts_keyrest || @required_keywords.present? || @optional_keywords.present?
      end

      def fixed_keywords?
        !@accepts_keyrest && (@required_keywords.present? || @optional_keywords.present?)
      end

      def validate(args, kwargs)
        args += [kwargs] unless kwargs.empty? || accepts_keywords?

        return argument_length_error(args.length) unless @arg_length.cover? args.length

        missing_keywords = @required_keywords - kwargs.keys
        return missing_keywords_error(missing_keywords) if missing_keywords.present?

        unknown_keywords = (kwargs.keys - @required_keywords - @optional_keywords if fixed_keywords?)
        return unknown_keywords_error(unknown_keywords) if unknown_keywords.present?

        nil
      end

      private

      def unknown_keywords_error(unknown_keywords)
        "unknown keyword#{"s" if unknown_keywords.many?}: #{
          unknown_keywords.map(&:inspect).join(", ")}"
      end

      def missing_keywords_error(missing_keywords)
        "missing keyword#{"s" if missing_keywords.many?}: #{
          missing_keywords.map(&:inspect).join(", ")}"
      end

      def argument_length_error(given_length)
        expected = @arg_length.begin.to_s
        if @arg_length.end.nil?
          expected += "+"
        elsif @arg_length.end > @arg_length.begin
          expected += "..#{@arg_length.end}"
        end
        "wrong number of arguments (given #{given_length}, expected #{expected})"
      end

      # Keeps track of the minimum and maximum number of allowed arguments
      class ArgumentCounter
        def initialize
          @min = @max = 0
        end

        def increment(type)
          @min += 1 if type == :req
          @max += 1 if @max
        end

        def clear_max
          @max = nil
        end

        def to_range
          @min..@max
        end
      end
    end

    private_constant :ArgumentValidator

    # Raised when an error occurs while configuring or executing asynchronous methods
    class Error < Exekutor::DiscardJob; end
  end
end
