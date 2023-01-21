module Exekutor
  # Contains internal classes
  # @private
  module Internal
    # Mixin for an executable
    module Executable
      # Possible states
      STATES = %i[pending started stopped crashed].freeze

      def initialize
        @state = Concurrent::AtomicReference.new(:pending)
      end

      # The state of this executable. Possible values are:
      # - +:pending+ the executable has not been started yet
      # - +:started+ the executable has started
      # - +:stopped+ the executable has stopped
      # - +:crashed+ the executable has crashed
      # @return [:pending,:started,:stopped,:crashed] the state
      def state
        @state.get
      end

      # Whether the state equals +:started+
      def running?
        @state.get == :started
      end

      private

      # Changes the state to the given value if the current state matches the expected state. Does nothing otherwise.
      # @param expected_state [:pending,:started,:stopped,:crashed] the expected state
      # @param new_state [:pending,:started,:stopped,:crashed] the state to change to if the current state matches the expected
      # @raise ArgumentError if an invalid state was passed
      def compare_and_set_state(expected_state, new_state)
        validate_state! new_state
        @state.compare_and_set expected_state, new_state
      end

      # Updates the state to the given value
      # @raise ArgumentError if an invalid state was passed
      def set_state(new_state)
        validate_state! new_state
        @state.set new_state
      end

      # Validates whether +state+ is a valid value
      # @raise ArgumentError if an invalid state was passed
      def validate_state!(state)
        raise ArgumentError, "State must be a symbol (was: #{state.class.name})" unless state.is_a? Symbol
        raise ArgumentError, "Invalid state: #{state}" unless STATES.include? state
      end
    end
  end
end