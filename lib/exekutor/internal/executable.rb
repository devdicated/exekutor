module Exekutor
  # @private
  module Internal

    module Executable
      STATES = %i[pending started stopped crashed].freeze

      def initialize
        @state = Concurrent::AtomicReference.new(:pending)
      end

      def state
        @state.get
      end

      def running?
        @state.get == :started
      end

      private

      def compare_and_set_state(expected_state, new_state)
        validate_state! new_state
        @state.compare_and_set expected_state, new_state
      end

      def set_state(new_state)
        validate_state! new_state
        @state.set new_state
      end

      def validate_state!(state)
        raise ArgumentError, "State must be a symbol (was: #{state.class.name})" unless state.is_a? Symbol
        raise ArgumentError, "Invalid state: #{state}" unless STATES.include? state
      end
    end
  end
end