# frozen_string_literal: true

module Exekutor
  # Contains internal classes
  # @private
  module Internal
    # Mixin for an executable
    module Executable
      # Possible states
      STATES = %i[pending started stopped crashed killed].freeze

      # Initializes the internal variables
      def initialize
        @state = Concurrent::AtomicReference.new(:pending)
        @consecutive_errors = Concurrent::AtomicFixnum.new(0)
      end

      # The state of this executable. Possible values are:
      # - +:pending+ the executable has not been started yet
      # - +:started+ the executable has started
      # - +:stopped+ the executable has stopped
      # - +:crashed+ the executable has crashed
      # - +:killed+ the executable was killed
      # @return [:pending,:started,:stopped,:crashed,:killed] the state
      def state
        @state.get
      end

      # @return [Boolean] whether the state equals +:started+
      def running?
        @state.get == :started
      end

      # @return [Concurrent::AtomicFixnum] the number of consecutive errors that have occurred
      def consecutive_errors
        @consecutive_errors
      end

      # Calculates an exponential delay based on {#consecutive_errors}. The delay ranges from 10 seconds on the first
      # error to 10 minutes from the 13th error on.
      # @return [Float] The delay
      def restart_delay
        if @consecutive_errors.value > 150
          error = SystemExit.new "Too many consecutive errors (#{@consecutive_errors.value})"
          Exekutor.on_fatal_error error
          raise error
        end
        delay = (9 + (@consecutive_errors.value**2.5))
        delay += delay * (rand(-5..5) / 100.0)
        delay.clamp(10.0, 600.0)
      end

      private

      # Changes the state to the given value if the current state matches the expected state. Does nothing otherwise.
      # @param expected_state [:pending,:started,:stopped,:crashed] the expected state
      # @param new_state [:pending,:started,:stopped,:crashed] the state to change to if the current state matches the
      #   expected
      # @raise ArgumentError if an invalid state was passed
      def compare_and_set_state(expected_state, new_state)
        validate_state! new_state
        @state.compare_and_set expected_state, new_state
      end

      # Updates the state to the given value
      # @raise ArgumentError if an invalid state was passed
      def state=(new_state)
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
