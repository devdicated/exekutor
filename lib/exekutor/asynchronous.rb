module Exekutor
  module Asynchronous
    extend ActiveSupport::Concern

    included do
      class_attribute :__asynchronous_methods, instance_writer: false, default: []
    end

    module ClassMethods
      def perform_asynchronous(method_name, immediate_method_name = "__#{method_name}_immediately")
        alias_method immediate_method_name, method_name

        define_method method_name do |*args, **kwargs|
          AsyncMethodJob.perform_later self, method_name, *args, **kwargs
        end
      end
    end

    # The internal job used for {Exekutor::Asynchronous}. Only works for objects which have included the
    # {Exekutor::Asynchronous} module and methods that are marked as asynchronous to prevent remote code execution.
    class AsyncMethodJob < ActiveJob::Base

      def perform(object, method, args, kwargs)
        check_object! object
        check_method! object, method
        object.send(method, *args, **kwargs)
      end

      private

      def check_object!(object)
        if object.nil?
          raise Exekutor::Error, "Object cannot be nil"
        elsif object.is_a? Class
          unless object.modules.include? Asynchronous
            raise Exekutor::Error, "Object has not included Exekutor::Asynchronous"
          end
        else
          raise Exekutor::Error, "Object has not included Exekutor::Asynchronous" unless object.is_a? Asynchronous
        end
      end

      def check_method!(object, method)
        raise Exekutor::Error, "Object does not respond to #{method}" unless object.respond_to? method, true
        unless object.__asynchronous_methods.include? method.to_sym
          raise Exekutor::Error, "Object##{method} is not marked as asynchronous"
        end
      end
    end
  end
end
