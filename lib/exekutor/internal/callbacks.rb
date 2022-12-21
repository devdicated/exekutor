module Exekutor
  module Internal
    module Callbacks
      extend ActiveSupport::Concern

      included do
        class_attribute :__callback_names, instance_writer: false, default: []
        attr_reader :__callbacks
        protected :__callbacks
      end

      def add_callback(type, *args, &callback)
        unless __callback_names.include? type
          raise Error, "Invalid callback type: #{type} (Expected one of: #{__callback_names.map(&:inspect).join(", ")}"
        end
        raise Error, "No callback block supplied" if callback.nil?

        add_callback! type, args, callback
        true
      end

      protected

      def run_callbacks(type, action, *args)
        callbacks = __callbacks && __callbacks[:"#{type}_#{action}"]
        unless callbacks
          yield(*args) if block_given?
          return
        end
        if type == :around
          # Chain all callbacks together, ending with the original given block
          callbacks.inject(-> { yield(*args) }) do |next_callback, (callback, extra_args)|
            if callback.arity.positive?
              -> do
                callback.call(*(args + extra_args)) { next_callback.call }
              rescue StandardError => err
                Exekutor.print_error err, "[Executor] Callback error!"
                next_callback.call
              end
            else
              -> do
                callback.call { next_callback.call }
              rescue StandardError => err
                Exekutor.print_error err, "[Executor] Callback error!"
                next_callback.call
              end
            end
          end.call
          return
        end
        iterator = type == :after ? :each : :reverse_each
        callbacks.send(iterator) do |(callback, extra_args)|
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
        nil
      end

      def with_callbacks(action, *args)
        run_callbacks :before, action, *args
        run_callbacks(:around, action, *args) { |fargs| yield(*fargs) }
        run_callbacks :after, action, *args
        nil
      end

      private

      def add_callback!(type, args, callback)
        @__callbacks ||= Concurrent::Hash.new
        __callbacks[type] ||= Concurrent::Array.new
        __callbacks[type] << [callback, args]
      end

      module ClassMethods
        def define_callbacks(*callbacks, freeze: true)
          callbacks.each do |name|
            unless /^(on_)|(before_)|(after_)|(around_)[a-z]+/.match? name.to_s
              raise Error, "Callback name should start with `on_`, `before_`, `after_`, or `around_`"
            end

            __callback_names << name
            module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{name}(*args, &callback)
                add_callback! :#{name}, args, callback
              end
            RUBY
          end

          __callback_names.freeze if freeze
        end
      end

      class Error < Exekutor::Error; end
    end
  end
end