module Exekutor
  module Internal
    class Hooks
      include Internal::Callbacks

      define_callbacks :before_enqueue, :around_enqueue, :after_enqueue,
                       :before_job_execution, :around_job_execution, :after_job_execution,
                       :on_job_failure, :on_fatal_error,
                       :before_startup, :after_startup,
                       :before_shutdown, :after_shutdown,
                       freeze: true

      # Registers a hook to be called.
      def register(callback = nil, &block)
        if callback
          callback = callback.new if callback.is_a? Class
          raise 'callback must respond to #callbacks' unless callback.respond_to? :callbacks
          callback.callbacks.each do |type, callbacks|
            callbacks.each { |callback| add_callback! type, [], callback }
          end
        elsif block.arity == 1
          block.call self
        else
          instance_eval(&block)
        end
      end

      # @see #register
      def <<(callback)
        register callback
      end

      # Executes an +:on+ callback with the given type.
      def self.on(type, *args)
        ::Exekutor.hooks.send(:run_callbacks, :on, type, *args)
      end

      # Executes the +:before+, +:around+, and +:after+ callbacks with the given type.
      def self.run(type, *args, &block)
        ::Exekutor.hooks.send(:with_callbacks, type, *args, &block)
      end
    end
  end

  # Prints the error to STDERR and the log, and calls the :on_fatal_error hooks.
  def self.on_fatal_error(error, message = nil)
    Exekutor.print_error(error, message)
    Internal::Hooks.on(:fatal_error, error)
  end

  # Exekutor.hooks.register do
  #    after_job_failure do |error, job|
  #       Appsignal.add_exception error
  #    end
  # end

  # Exekutor.hooks.after_job_failure do error
  #    Appsignal.add_exception error
  # end

  # class ExekutorHooks < ::Exekutor::Hook
  #   around_job_execution :instrument
  #   after_job_failure :report_error
  #   after_fatal_error :report_error
  #
  #   def instrument(job)
  #     Appsignal.monitor_transaction … { yield }
  #   end
  #
  #   def send_to_appsignal(error)
  #       Appsignal.add_exception error
  #   end
  # end
  #
  # Exekutor.hooks.register ExekutorHooks

  # @!attribute [r] hooks
  #   @return [Internal::Hooks] The hooks for exekutor.
  mattr_reader :hooks, default: Internal::Hooks.new

  # TODO register_hook method instead of `hooks.register`?
end