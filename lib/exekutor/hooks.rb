module Exekutor
  class Hook
    include Internal::Callbacks

    define_callbacks :before_enqueue, :around_enqueue, :after_enqueue,
                     :before_job_execution, :around_job_execution, :after_job_execution,
                     :on_job_failure, :on_fatal_error,
                     :before_startup, :after_startup,
                     :before_shutdown, :after_shutdown,
                     freeze: true

    # Exekutor.hooks.register do
    #    after_job_failure do |error, job|
    #       Appsignal.add_exception error
    #    end
    # end

    # Exekutor.hooks.after_job_failure do error
    #    Appsignal.add_exception error
    # end

    # TODO this aint working yet
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

    def register(callback = nil, &block)
      if callback
        callback = callback.new if callback.is_a? Class
        raise 'callback must include the Exekutor::Hook module' unless callback.is_a? Exekutor::Hook
        callback.send(:__callbacks).each do |type, callbacks|
          callbacks.each { |(callback, args)| add_callback! type, args, callback }
        end
      elsif block.arity.positive?
        block.call self
      else
        instance_eval &block
      end
    end

    def <<(callback)
      register callback
    end
  end

  mattr_reader :hooks, default: Hook.new
end