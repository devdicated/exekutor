# frozen_string_literal: true

raise Exekutor::Plugins::LoadError, "Appsignal not found, is the gem loaded?" unless defined? Appsignal

module Exekutor
  module Plugins
    # Hooks to send job execution info and raised errors to Appsignal
    class Appsignal
      include Hook
      before_shutdown { ::Appsignal.stop("exekutor") }

      around_job_execution :invoke_with_instrumentation

      on_job_failure { |_job, error| report_error error }
      on_fatal_error :report_error

      def invoke_with_instrumentation(job)
        payload = job[:payload]
        params = ::Appsignal::Utils::HashSanitizer.sanitize(
          payload.fetch("arguments", {}),
          ::Appsignal.config[:filter_parameters]
        )

        ::Appsignal.monitor_transaction(
          "perform_job.exekutor",
          class: payload["job_class"],
          method: "perform",
          params: params,
          metadata: {
            id: payload["job_id"],
            queue: payload["queue_name"],
            priority: payload.fetch("priority", Exekutor.config.default_queue_priority),
            attempts: payload.fetch("attempts", 0)
          },
          queue_start: job[:scheduled_at]
        ) do
          yield job
        end
      end

      def report_error(error)
        ::Appsignal.add_exception(error)
      end
    end
  end
end

Exekutor.hooks.register Exekutor::Plugins::Appsignal
