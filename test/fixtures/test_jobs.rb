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

  class Blocking < ActiveJob::Base
    mattr_accessor :block, default: true

    def perform
      sleep 0.01 while block
    end
  end

  class Raises < ActiveJob::Base
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
