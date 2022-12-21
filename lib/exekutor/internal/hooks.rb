module Exekutor
  module Internal
    module Hooks
      def self.on(type, *args)
        ::Exekutor::hooks.send(:run_callbacks, :on, type, args)
      end

      def self.run(type, *args, &block)
        ::Exekutor::hooks.send(:with_callbacks, type, args, &block)
      end
    end
  end
end