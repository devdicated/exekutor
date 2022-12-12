module Exekutor
  # Mixin to let methods be executed asynchronously by active job
  module Asynchronous
    extend ActiveSupport::Concern

    included do
      mattr_reader :__async_class_methods, instance_accessor: false, default: {}
      mattr_reader :__async_instance_methods, instance_accessor: false, default: {}
    end

    module ClassMethods
      # Changes a method to be executed asynchronously
      # @param method_name [Symbol]
      def perform_asynchronously(method_name, alias_to: "__immediately_#{method_name}", class_method: false)
        raise Error, "method_name must be a Symbol (actual: #{method_name.class.name})" unless method_name.is_a? Symbol
        raise Error, "alias_to must be present" unless alias_to.present?
        if class_method
          raise Error, "##{method_name} does not exist" unless respond_to? method_name, true

          delegate = singleton_class
          definitions = __async_class_methods
        else
          unless method_defined?(method_name, true) || private_method_defined?(method_name, true)
            raise Error, "##{method_name} does not exist"
          end

          delegate = self
          definitions = __async_instance_methods
        end
        if definitions.include? method_name
          raise Error, "##{method_name} was already marked as asynchronous"
        end

        delegate.alias_method alias_to, method_name
        delegate.define_method method_name do |*args, **kwargs|
          error = Asynchronous.validate_args(self, alias_to, *args, **kwargs)
          raise error if error
          raise ArgumentError, "Cannot asynchronously execute with a block argument" if block_given?
          AsyncMethodJob.perform_later self, method_name, *args, **kwargs
        end

        definitions[method_name] = alias_to
        if delegate.public_method_defined?(alias_to)
          public method_name
        elsif delegate.protected_method_defined?(alias_to)
          protected method_name
        else
          private method_name
        end
      end
    end

    private

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
        if type == :req
          min_arg_length += 1
          max_arg_length += 1 if max_arg_length
        elsif type == :opt
          max_arg_length += 1 if max_arg_length
        elsif type == :rest
          max_arg_length = nil
        elsif type == :keyreq
          accepts_keywords = true
          missing_keywords << name if kwargs.exclude?(name)
        elsif type == :key
          accepts_keywords = true
          unknown_keywords.delete(name)
        elsif type == :keyrest
          accepts_keywords = true
          unknown_keywords = []
        end
      end
      if missing_keywords.present?
        return ArgumentError.new "missing keyword#{"s" if missing_keywords.many?}: #{missing_keywords.map(&:inspect).join(", ")}"
      end
      if accepts_keywords
        if unknown_keywords.present?
          return ArgumentError.new "unknown keyword#{"s" if unknown_keywords.many?}: #{unknown_keywords.map(&:inspect).join(", ")}"
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
    end

    # The internal job used for {Exekutor::Asynchronous}. Only works for objects which have included the
    # {Exekutor::Asynchronous} module and methods that are marked as asynchronous to prevent remote code execution.
    class AsyncMethodJob < ActiveJob::Base

      def perform(object, method, *args, **kwargs)
        check_object! object
        method_alias = check_method! object, method
        object.__send__(method_alias, *args, **kwargs)
      end

      private

      def check_object!(object)
        if object.nil?
          raise Exekutor::Error, "Object cannot be nil"
        elsif object.is_a? Class
          unless object.included_modules.include? Asynchronous
            raise Exekutor::Error, "Object has not included Exekutor::Asynchronous"
          end
        else
          raise Exekutor::Error, "Object has not included Exekutor::Asynchronous" unless object.is_a? Asynchronous
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
        unless object.respond_to? method, true
          raise Exekutor::Error, "#{class_name} does not respond to #{method}"
        end
        unless definitions.include? method.to_sym
          raise Exekutor::Error, "#{class_name}##{method} is not marked as asynchronous"
        end
        definitions[method.to_sym]
      end
    end
  end
end