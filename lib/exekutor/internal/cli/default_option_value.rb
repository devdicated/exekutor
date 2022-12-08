module Exekutor
  # @private
  module Internal
    module CLI
      class DefaultOptionValue
        def initialize(value)
          @value = value
        end

        def to_s
          @value
        end
      end
    end
  end
end