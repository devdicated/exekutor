# frozen_string_literal: true

require "test_helper"
class PluginTest < Minitest::Test
  def test_appsignal_plugin
    File.expects(:exist?).with(regexp_matches(%r{/exekutor/lib/exekutor/plugins/test_plugin\.rb$})).returns(true)
    begin
      ::Exekutor.load_plugin :test_plugin
    rescue LoadError => e
      assert_match %r{/exekutor/lib/exekutor/plugins/test_plugin$}, e.message
    end
  end

  def test_nonexistent_plugin
    assert_raises(::Exekutor::Plugins::LoadError) { ::Exekutor.load_plugin :nonexistent }
  end
end
