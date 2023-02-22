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
    #      def with_callbacks
    #        run_callbacks :another_event, self
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
              lambda do
                callback.call(*(args + extra_args)) { next_callback.call }
              rescue StandardError => err
                Exekutor.on_fatal_error err, "[Executor] Callback error!"
                next_callback.call
              end
            else
              lambda do
                callback.call { next_callback.call }
              rescue StandardError => err
                Exekutor.on_fatal_error err, "[Executor] Callback error!"
                next_callback.call
              end
            end
          end.call
          return
        end
        iterator = type == :after ? :each : :reverse_each
        callbacks.send(iterator) do |(callback, extra_args)|
          begin
            if callback.arity.zero?
              callback.call
            else
              callback.call(*(args + extra_args))
            end
          rescue StandardError => err
            if action == :fatal_error
              # Just print the error to prevent an infinite loop
              Exekutor.print_error err, "[Executor] Callback error!"
            else
              Exekutor.on_fatal_error err, "[Executor] Callback error!"
            end
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

      def add_callback!(type, args, callback)
        @__callbacks ||= Concurrent::Hash.new
        __callbacks[type] ||= Concurrent::Array.new
        __callbacks[type] << [callback, args]
      end

      class_methods do
        # Defines the specified callbacks on this class. Also defines a method with the given name to register the callback.
        # @param callbacks [Symbol] the callback names to define. Must start with +on_+, +before_+, +after_+, or +around_+.
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
              def #{name}(*args, &callback)
                add_callback! :#{name}, args, callback
              end
            RUBY
          end

          __callback_names.freeze if freeze
        end
      end

      # Raised when registering a callback fails
      class Error < Exekutor::Error; end
    end
  end
end