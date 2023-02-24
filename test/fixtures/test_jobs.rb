module TestJobs
  class Simple < ActiveJob::Base
    mattr_accessor :executed, default: false

    def perform
      self.executed = true
    end
  end

  class WithOptions < ActiveJob::Base
    mattr_accessor :executed, default: false
    include Exekutor::JobOptions

    def perform
      self.executed = true
    end
  end
end