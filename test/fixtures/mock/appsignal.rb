# frozen_string_literal: true

class Appsignal
  class << self
    def config
      {}
    end

    def add_exception(_) end

    def monitor_transaction(_)
      yield if block_given?
    end

    def stop(_) end
  end

  module Utils
    class HashSanitizer
      def self.sanitize(obj, _)
        obj
      end
    end
  end
end
