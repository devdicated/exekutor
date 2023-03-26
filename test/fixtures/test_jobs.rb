# frozen_string_literal: true

module TestJobs
  class ApplicationJob < ActiveJob::Base; end

  class Simple < ApplicationJob
    mattr_accessor :executed, default: false

    def perform
      self.executed = true
    end
  end

  class WithOptions < ApplicationJob
    mattr_accessor :executed, default: false
    include Exekutor::JobOptions

    def perform
      self.executed = true
    end
  end

  class Blocking < ApplicationJob
    mattr_accessor :block, default: true

    def perform
      sleep 0.01 while block
    end
  end

  class Raises < ApplicationJob
    def perform(error = nil, message = nil)
      if error && message
        raise error, message
      elsif error || message
        raise error || message
      else
        raise "This job raises an error by default"
      end
    end
  end
end
