# frozen_string_literal: true

require_relative "../test_helper"

class DatabaseConnectionTest < Minitest::Test
  def test_set_application_name
    connection = mock
    connection.stubs(:escape_identifier).with("Exekutor[id: 1234]").returns("'Exekutor[id: 1234]'")
    connection.expects(:exec).with("SET application_name = 'Exekutor[id: 1234]'")
    ::Exekutor.const_get(:Internal)::DatabaseConnection.set_application_name(connection, 1234)
  end

  def test_application_name
    assert_equal "Exekutor[id: 1234]",
                 ::Exekutor.const_get(:Internal)::DatabaseConnection.application_name(1234)

    assert_equal "Exekutor[id: 5678] process",
                 ::Exekutor.const_get(:Internal)::DatabaseConnection.application_name(5678, :process)
  end

  def test_ensure_active_while_active
    active_connection = mock
    active_connection.expects(:active?).returns(true)
    ::Exekutor.const_get(:Internal)::DatabaseConnection.ensure_active! active_connection
  end

  def test_ensure_active_while_inactive
    inactive_connection = mock
    inactive_connection.expects(:active?).returns(false)
    inactive_connection.expects(:reconnect!)

    ::Exekutor.const_get(:Internal)::DatabaseConnection.ensure_active! inactive_connection
  end
end
