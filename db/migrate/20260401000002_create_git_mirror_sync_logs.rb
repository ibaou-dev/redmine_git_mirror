class CreateGitMirrorSyncLogs < ActiveRecord::Migration[7.2]
  def change
    create_table :git_mirror_sync_logs do |t|
      t.integer  :git_mirror_config_id, null: false
      t.string   :trigger_type,         null: false, limit: 20
      t.datetime :started_at,           null: false
      t.datetime :completed_at
      t.string   :status,               null: false, limit: 20
      t.integer  :commits_fetched,      default: 0
      t.text     :output
      t.text     :error_message

      t.timestamps null: false
    end

    add_index :git_mirror_sync_logs, :git_mirror_config_id
    add_index :git_mirror_sync_logs,
              [:git_mirror_config_id, :started_at],
              name: 'idx_git_mirror_sync_logs_config_started'
    add_index :git_mirror_sync_logs, :status
  end
end
