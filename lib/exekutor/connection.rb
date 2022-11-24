module Exekutor
  module Connection
    def self.set_application_name(pg_conn, id, process = nil)
      pg_conn.exec("SET application_name = #{pg_conn.escape_identifier(application_name(id, process))}")
    end

    def self.application_name(id, process = nil)
      "Exekutor[id: #{id}]#{" #{process}" if process}"
    end
  end
end