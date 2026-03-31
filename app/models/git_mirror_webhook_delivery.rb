class GitMirrorWebhookDelivery < ActiveRecord::Base
  belongs_to :git_mirror_config

  validates :git_mirror_config_id, presence: true
  validates :delivery_uuid,        presence: true, uniqueness: true
  validates :received_at,          presence: true

  # Check if a delivery UUID has been seen in the last 10 minutes
  def self.seen?(uuid)
    return false if uuid.blank?

    where(delivery_uuid: uuid)
      .where('received_at > ?', 10.minutes.ago)
      .exists?
  end

  # Record a new delivery
  def self.record!(config_id, uuid)
    create!(
      git_mirror_config_id: config_id,
      delivery_uuid:        uuid,
      received_at:          Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    # Duplicate delivery — already recorded, which is fine
    nil
  end

  # Delete deliveries older than 15 minutes (called periodically)
  def self.cleanup_old!
    where('received_at < ?', 15.minutes.ago).delete_all
  end
end
