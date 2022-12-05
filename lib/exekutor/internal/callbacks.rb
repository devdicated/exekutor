module Exekutor
  module Internal
    module Callbacks
      extend ActiveSupport::Concern

      included do
        class_attribute :__callbacks, instance_writer: false, default: {}
      end

      def add_callback(type, *args, &callback)
        unless __callbacks.include? type
          raise Error, "Invalid callback type: #{type} (Expected one of: #{__callbacks.keys.map(&:inspect).join(", ")}"
        end
        raise Error, "No callback block supplied" if callback.nil?

        __callbacks[type] << [callback, args]
      end

      protected

      def run_callbacks(type, *args)
        __callbacks[type]&.each do |(callback, extra_args)|
          begin
            if callback.arity.positive?
              callback.call(*(args + extra_args))
            else
              callback.call
            end
          rescue StandardError => err
            Exekutor.print_error err, "[Executor] Callback error!"
          end
        end
      end

      module ClassMethods
        def define_callbacks(*callbacks, freeze: true)
          callbacks.each do |name|
            unless /^(on_)|(before_)|(after_)[a-z]+/.match? name.to_s
              raise Error, "Callback name should start with `on_`, `before_`, or `after_`"
            end

            __callbacks[name] ||= Concurrent::Array.new
            module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{name}(*args, &callback)
                __callbacks[:#{name}] << [callback, args]
              end
            RUBY
          end

          __callbacks.freeze if freeze
        end
      end

      class Error < Exekutor::Error; end
    end
  end
end