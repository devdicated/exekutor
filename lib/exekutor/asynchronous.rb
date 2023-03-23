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
      private_class_method :perform_asynchronously
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
        raise ArgumentError, "alias_to must be present" unless alias_to.present?

        if class_method
          raise ArgumentError, "##{method_name} does not exist" unless respond_to? method_name, true

          delegate = singleton_class
          definitions = __async_class_methods
        else
          unless method_defined?(method_name, true) || private_method_defined?(method_name, true)
            raise ArgumentError, "##{method_name} does not exist"
          end

          delegate = self
          definitions = __async_instance_methods
        end
        raise Error, "##{method_name} was already marked as asynchronous" if definitions.include? method_name

        delegate.alias_method alias_to, method_name
        delegate.define_method method_name do |*args, **kwargs|
          error = Asynchronous.validate_args(self, alias_to, *args, **kwargs)
          raise error if error
          raise ArgumentError, "Cannot asynchronously execute with a block argument" if block_given?

          AsyncMethodJob.perform_later self, method_name, [args, kwargs.presence]
        end

        definitions[method_name] = alias_to
        if delegate.public_method_defined?(alias_to)
          delegate.send :public, method_name
        elsif delegate.protected_method_defined?(alias_to)
          delegate.send :protected, method_name
        else
          delegate.send :private, method_name
        end
      end
    end

    # Validates whether the given arguments match the expected parameters for +method+
    # @param delegate [Object] the object the +method+ will be called on
    # @param method [Symbol] the method that will be called on +delegate+
    # @param args [Array] the arguments that will be given to the method
    # @param kwargs [Hash] the keyword arguments that will be given to the method
    # @return [ArgumentError,nil] nil if the keywords are valid; an ArgumentError otherwise
    def self.validate_args(delegate, method, *args, **kwargs)
      obj_method = delegate.method(method)
      min_arg_length = 0
      max_arg_length = 0
      accepts_keywords = false
      missing_keywords = []
      unknown_keywords = kwargs.keys
      obj_method.parameters.each do |type, name|
        case type
        when :req
          min_arg_length += 1
          max_arg_length += 1 if max_arg_length
        when :opt
          max_arg_length += 1 if max_arg_length
        when :rest
          max_arg_length = nil
        when :keyreq
          accepts_keywords = true
          missing_keywords << name if kwargs.exclude?(name)
          unknown_keywords.delete(name)
        when :key
          accepts_keywords = true
          unknown_keywords.delete(name)
        when :keyrest
          accepts_keywords = true
          unknown_keywords = []
        else
          Exekutor.say "Unsupported parameter type: #{type.inspect}"
        end
      end
      if missing_keywords.present?
        return ArgumentError.new "missing keyword#{
          if missing_keywords.many?
            "s"
          end}: #{missing_keywords.map(&:inspect).join(", ")}"
      end

      if accepts_keywords
        if unknown_keywords.present?
          return ArgumentError.new "unknown keyword#{
            if unknown_keywords.many?
              "s"
            end}: #{unknown_keywords.map(&:inspect).join(", ")}"
        end
      elsif kwargs.present?
        args += [kwargs]
      end

      args_len = args.length
      if min_arg_length > args_len || (max_arg_length.present? && max_arg_length < args_len)
        expected = min_arg_length.to_s
        if max_arg_length.nil?
          expected += "+"
        elsif max_arg_length > min_arg_length
          expected += "..#{max_arg_length}"
        end
        return ArgumentError.new "wrong number of arguments (given #{args_len}, expected #{expected})"
      end

      nil
    end

    # The internal job used for {Exekutor::Asynchronous}. Only works for methods that are marked as asynchronous to
    # prevent remote code execution. Include the {Exekutor::Asynchronous} and call
    # {Exekutor::Asynchronous#perform_asynchronously} to mark a method as asynchronous.
    class AsyncMethodJob < ActiveJob::Base
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

    # Raised when an error occurs while configuring or executing asynchronous methods
    class Error < Exekutor::DiscardJob; end
  end
end
