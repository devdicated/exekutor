# frozen_string_literal: true

require "test_helper"

class ExekutorTest < Minitest::Test
  def test_version_set
    refute_nil ::Exekutor::VERSION
  end
end

