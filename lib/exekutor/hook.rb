# frozen_string_literal: true

module Exekutor
  # Defines hooks for Exekutor.
  #
  # @example Define and register hooks
  #    class ExekutorHooks
  #      include Exekutor::Hook
  #      around_job_execution :instrument
  #      after_job_failure {|_job, error| report_error error }
  #      after_fatal_error :report_error
  #
  #      def instrument(job)
  #        ErrorMonitoring.monitor_transaction { yield }
  #      end
  #
  #      def report_error(error)
  #        ErrorMonitoring.report error
  #      end
  #    end
  #
  #    Exekutor.hooks.register ExekutorHooks
  module Hook
    extend ActiveSupport::Concern

    CALLBACK_NAMES = %i[
      before_enqueue around_enqueue after_enqueue before_job_execution around_job_execution after_job_execution
      on_job_failure on_fatal_error before_startup after_startup before_shutdown after_shutdown
    ].freeze
    private_constant "CALLBACK_NAMES"

    included do
      class_attribute :__callbacks, default: Hash.new { |h, k| h[k] = [] }

      private_class_method :add_callback!
    end

    # Gets the registered callbacks
    # @return [Hash<Symbol,Array<Proc>>] the callbacks
    def callbacks
      instance = self
      __callbacks.transform_values do |callbacks|
        callbacks.map do |method, callback|
          if method
            method(method)
          elsif callback.arity.zero?
            -> { instance.instance_exec(&callback) }
          else
            ->(*args) { instance.instance_exec(*args, &callback) }
          end
        end
      end
    end

    class_methods do

      # @!method before_enqueue
      #   Registers a callback to be called before a job is enqueued.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam job [ActiveJob::Base] the job to enqueue
      #   @return [void]

      # @!method after_enqueue
      #   Registers a callback to be called after a job is enqueued.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam job [ActiveJob::Base] the enqueued job
      #   @return [void]

      # @!method around_enqueue
      #   Registers a callback to be called when a job is enqueued. You must call +yield+ from the callback.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam job [ActiveJob::Base] the job to enqueue
      #   @return [void]

      # @!method before_job_execution
      #   Registers a callback to be called before a job is executed.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam job [Hash] the job to execute
      #   @return [void]

      # @!method after_job_execution
      #   Registers a callback to be called after a job is executed.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam job [Hash] the executed job
      #   @return [void]

      # @!method around_job_execution
      #   Registers a callback to be called when a job is executed. You must call +yield+ from the callback.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam job [Hash] the job to execute
      #   @return [void]

      # @!method on_job_failure
      #   Registers a callback to be called when a job raises an error.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam job [Hash] the job that was executed
      #   @yieldparam error [StandardError] the error that was raised
      #   @return [void]

      # @!method on_fatal_error
      #   Registers a callback to be called when an error is raised from a worker outside a job.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam error [StandardError] the error that was raised
      #   @return [void]

      # @!method before_startup
      #   Registers a callback to be called before a worker is starting up.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam worker [Worker] the worker
      #   @return [void]

      # @!method after_startup
      #   Registers a callback to be called after a worker has started up.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam worker [Worker] the worker
      #   @return [void]

      # @!method before_shutdown
      #   Registers a callback to be called before a worker is shutting down.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam worker [Worker] the worker
      #   @return [void]

      # @!method after_shutdown
      #   Registers a callback to be called after a worker has shutdown.
      #   @param methods [Symbol] the method(s) to call
      #   @yield the block to call
      #   @yieldparam worker [Worker] the worker
      #   @return [void]

      CALLBACK_NAMES.each do |name|
        module_eval <<-RUBY, __FILE__, __LINE__ + 1
          def #{name}(*methods, &callback)
            add_callback! :#{name}, methods, callback
          end
        RUBY
      end

      # Adds a callback.
      # @param type [Symbol] the callback to register
      # @param methods [Symbol] the method(s) to call
      # @yield the block to call
      def add_callback(type, *methods, &callback)
        unless CALLBACK_NAMES.include? type
          raise Error, "Invalid callback type: #{type} (Expected one of: #{CALLBACK_NAMES.map(&:inspect).join(", ")}"
        end

        add_callback! type, methods, callback
        true
      end

      def add_callback!(type, methods, callback)
        raise Error, "No method or callback block supplied" if methods.blank? && callback.nil?
        raise Error, "Either a method or a callback block must be supplied" if methods.present? && callback.present?

        methods&.each { |method| __callbacks[type] << [method, nil] }
        __callbacks[type] << [nil, callback] if callback.present?
      end
    end
  end
end
