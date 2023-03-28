# frozen_string_literal: true

module Exekutor
  module Internal
    # Mixin to define callbacks on a class
    #
    # @example Define and call callbacks
    #    class MyClass
    #      include Exekutor::Internal::Callbacks
    #
    #      define_callbacks :on_event, :before_another_event, :after_another_event
    #
    #      def emit_event
    #        run_callbacks :on, :event, "Callback arg"
    #      end
    #
    #      def emit_another_event
    #        with_callbacks :another_event, self do |self_arg|
    #          puts "another event"
    #        end
    #      end
    #    end
    #    MyClass.new.on_event(12) {|str, int| puts "event happened: #{str}, #{int}" }
    module Callbacks
      extend ActiveSupport::Concern

      included do
        class_attribute :__callback_names, instance_writer: false, default: []
        attr_reader :__callbacks
        protected :__callbacks
      end

      # Adds a callback.
      # @param type [Symbol] the type of callback to add
      # @param args [Any] the args to forward to the callback
      # @yield the block to call
      # @yieldparam *args [Any] the callback args, appended by the specified args
      def add_callback(type, *args, &callback)
        unless __callback_names.include? type
          raise Error, "Invalid callback type: #{type} (Expected one of: #{__callback_names.map(&:inspect).join(", ")}"
        end
        raise Error, "No callback block supplied" if callback.nil?

        add_callback! type, args, callback
        true
      end

      protected

      # Runs all callbacks for the specified type and action.
      # @param type [:on, :before, :around, :after] the type of the callback
      # @param action [Symbol] the name of the callback
      # @param args [Any] the callback args
      def run_callbacks(type, action, *args, &block)
        callbacks = __callbacks && __callbacks[:"#{type}_#{action}"]
        unless callbacks
          yield(*args) if block
          return
        end
        if type == :around
          chain_callbacks(callbacks, args, &block).call
        else
          # Invoke :before in reverse order (last registered first),
          # invoke :after in original order (last registered last)
          iterator = type == :after ? :each : :reverse_each
          callbacks.send(iterator) do |(callback, extra_args)|
            invoke_callback(callback, args, extra_args)
          end
        end
        nil
      end

      # Runs :before, :around, and :after callbacks for the specified action.
      def with_callbacks(action, *args)
        run_callbacks :before, action, *args
        run_callbacks(:around, action, *args) { |*fargs| yield(*fargs) }
        run_callbacks :after, action, *args
        nil
      end

      private

      # Chain all callbacks together, ending with the original given block
      def chain_callbacks(callbacks, args)
        callbacks.inject(-> { yield(*args) }) do |next_callback, (callback, extra_args)|
          # collect args outside of the lambda
          callback_args = if callback.arity.zero?
                            []
                          else
                            args + extra_args
                          end
          lambda do
            has_yielded = false
            callback.call(*callback_args) do
              has_yielded = true
              next_callback.call
            end
            raise MissingYield, "Callback did not yield!" unless has_yielded
          rescue StandardError => e
            raise if e.is_a? MissingYield

            Exekutor.on_fatal_error e, "[Executor] Callback error!"
            next_callback.call
          end
        end
      end

      def invoke_callback(callback, args, extra_args)
        if callback.arity.zero?
          callback.call
        else
          callback.call(*(args + extra_args))
        end
      rescue StandardError => e
        Exekutor.on_fatal_error e, "[Executor] Callback error!"
      end

      def add_callback!(type, args, callback)
        @__callbacks ||= Concurrent::Hash.new
        __callbacks[type] ||= Concurrent::Array.new
        __callbacks[type] << [callback, args]
      end

      class_methods do
        # Defines the specified callbacks on this class. Also defines a method with the given name to register the
        # callback.
        # @param callbacks [Symbol] the callback names to define. Must start with +on_+, +before_+, +after_+, or
        #   +around_+.
        # @param freeze [Boolean] if true, freezes the callbacks so that no other callbacks can be defined
        # @raise [Error] if a callback name is invalid or if the callbacks are frozen
        def define_callbacks(*callbacks, freeze: true)
          raise Error, "Callbacks are frozen, no other callbacks may be defined" if __callback_names.frozen?

          callbacks.each do |name|
            unless /^(on_)|(before_)|(after_)|(around_)[a-z]+/.match? name.to_s
              raise Error, "Callback name must start with `on_`, `before_`, `after_`, or `around_`"
            end

            __callback_names << name
            module_eval <<-RUBY, __FILE__, __LINE__ + 1
              def #{name}(*args, &callback)             # def callback_method(*args, &callback
                add_callback! :#{name}, args, callback  #   add_callback! :callback_method, args, callback
              end                                       # end
            RUBY
          end

          __callback_names.freeze if freeze
        end
      end

      # Raised when registering a callback fails
      class Error < Exekutor::Error; end

      # Raised when an around callback does not yield
      class MissingYield < Exekutor::Error; end
    end
  end
end
