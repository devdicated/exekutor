module Exekutor
  # @private
  module Internal
    module CLI
      # Used as a default value for CLI flags.
      # @private
      class DefaultOptionValue
        def initialize(description = nil, value: nil)
          @description = description || value&.to_s || "none"
          @value = value
        end

        # The value to display in the CLI help message
        def to_s
          @description
        end

        # The actual value, if set. If the value responds to +call+, it will be called
        def value
          if @value.respond_to? :call
            @value.call
          else
            @value
          end
        end
      end
    end
  end
end