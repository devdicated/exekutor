# frozen_string_literal: true

class CreateExekutorSchema < ActiveRecord::Migration[6.0]
  def change
    create_table :exekutor_workers, id: :uuid do |t|
      t.string :hostname, null: false, limit: 255
      t.integer :pid, null: false

      t.jsonb :info, null: false

      t.datetime :started_at, null: false, default: -> { "now()" }
      t.datetime :last_heartbeat_at, null: false, default: -> { "now()" }

      t.column :status, :char, null: false, default: "i"

      t.index %i[hostname pid], unique: true
    end

    create_table :exekutor_jobs, id: :uuid do |t|
      # Worker options
      t.string :queue, null: false, default: "default", limit: 200, index: true
      t.integer :priority, null: false, default: 16_383, limit: 2
      t.datetime :enqueued_at, null: false, default: -> { "now()" }
      t.datetime :scheduled_at, null: false, default: -> { "now()" }

      # Job options
      t.uuid :active_job_id, null: false, index: true
      t.jsonb :payload, null: false
      t.jsonb :options

      # Execution options
      t.column :status, :char, index: true, null: false, default: "p"
      t.float :runtime
      t.references :worker, type: :uuid, foreign_key: { to_table: :exekutor_workers, on_delete: :nullify }

      t.index %i[priority scheduled_at enqueued_at], where: %q("status"='p'),
              name: :index_exekutor_jobs_on_dequeue_order
    end

    create_table :exekutor_job_errors, id: :uuid do |t|
      t.references :job, type: :uuid, null: false, foreign_key: { to_table: :exekutor_jobs, on_delete: :cascade }
      t.datetime :created_at, null: false, default: -> { "now()" }
      t.jsonb :error, null: false
    end
  end
end
