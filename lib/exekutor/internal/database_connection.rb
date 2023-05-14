# frozen_string_literal: true

module Exekutor
  # @private
  module Internal
    # Helper methods for the DB connection name
    module DatabaseConnection
      # Sets the connection name
      def self.set_application_name(pg_conn, id, process = nil)
        pg_conn.exec("SET application_name = #{pg_conn.escape_identifier(application_name(id, process))}")
      end

      # The connection name for the specified worker id and process
      # @param id [String] the id of the worker
      # @param process [nil,String] the process name
      def self.application_name(id, process = nil)
        "Exekutor[id: #{id}]#{" #{process}" if process}"
      end

      # Reconnects the database if it is not active
      # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter] the connection adapter to use
      def self.ensure_active!(connection = BaseRecord.connection)
        connection.reconnect! unless connection.active?
      end
    end
  end
end
