module Exekutor
  # @private
  module Internal
    # Helper methods for the DB connection name
    module Connection
      # Sets the connection name
      def self.set_application_name(pg_conn, id, process = nil)
        pg_conn.exec("SET application_name = #{pg_conn.escape_identifier(application_name(id, process))}")
      end

      # The connection name for the specified worker id and process
      def self.application_name(id, process = nil)
        "Exekutor[id: #{id}]#{" #{process}" if process}"
      end
    end
  end
end