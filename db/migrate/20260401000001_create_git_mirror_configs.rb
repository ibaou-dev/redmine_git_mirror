class CreateGitMirrorConfigs < ActiveRecord::Migration[7.2]
  def change
    create_table :git_mirror_configs do |t|
      t.integer  :repository_id,      null: false
      t.string   :remote_url,         null: false, limit: 512
      t.string   :auth_type,          null: false, default: 'none', limit: 20

      # SSH key (filesystem-managed, only filename stored)
      t.string   :ssh_key_filename,   limit: 255

      # Token / userpass (DB-encrypted via Redmine::Ciphering)
      t.text     :username_enc
      t.text     :password_enc
      t.text     :access_token_enc

      # Polling
      t.boolean  :poll_enabled,       null: false, default: true
      t.string   :poll_cron,          limit: 100, default: '*/15 * * * *'

      # Webhook
      t.boolean  :webhook_enabled,    null: false, default: false
      t.text     :webhook_secret_enc
      t.string   :webhook_token,      null: false, limit: 64

      # State
      t.string   :local_path,         limit: 512
      t.boolean  :syncing,            null: false, default: false
      t.datetime :sync_started_at
      t.datetime :last_sync_at
      t.string   :last_sync_status,   limit: 20
      t.text     :last_error_message

      t.timestamps null: false
    end

    add_index :git_mirror_configs, :repository_id, unique: true
    add_index :git_mirror_configs, :webhook_token, unique: true
  end
end
