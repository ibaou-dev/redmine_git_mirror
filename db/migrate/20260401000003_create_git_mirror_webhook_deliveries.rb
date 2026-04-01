class CreateGitMirrorWebhookDeliveries < ActiveRecord::Migration[7.2]
  def change
    create_table :git_mirror_webhook_deliveries do |t|
      t.integer  :git_mirror_config_id, null: false
      t.string   :delivery_uuid,        null: false, limit: 255
      t.datetime :received_at,          null: false
    end

    add_index :git_mirror_webhook_deliveries, :delivery_uuid, unique: true
    add_index :git_mirror_webhook_deliveries, :received_at
    add_index :git_mirror_webhook_deliveries, :git_mirror_config_id
  end
end
