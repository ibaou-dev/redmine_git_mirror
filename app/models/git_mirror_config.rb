class GitMirrorConfig < ActiveRecord::Base
  include Redmine::Ciphering
  include Redmine::SafeAttributes

  AUTH_TYPES = %w[none ssh_key token userpass].freeze
  SYNC_STATUSES = %w[pending success failed].freeze

  # Associations
  belongs_to :repository
  has_many :sync_logs,
           class_name:  'GitMirrorSyncLog',
           foreign_key: 'git_mirror_config_id',
           dependent:   :destroy
  has_many :webhook_deliveries,
           class_name:  'GitMirrorWebhookDelivery',
           foreign_key: 'git_mirror_config_id',
           dependent:   :destroy

  # Encrypted attribute accessors (columns: username_enc, password_enc, access_token_enc, webhook_secret_enc)
  def username
    read_ciphered_attribute(:username_enc)
  end

  def username=(val)
    write_ciphered_attribute(:username_enc, val)
  end

  def password
    read_ciphered_attribute(:password_enc)
  end

  def password=(val)
    write_ciphered_attribute(:password_enc, val)
  end

  def access_token
    read_ciphered_attribute(:access_token_enc)
  end

  def access_token=(val)
    write_ciphered_attribute(:access_token_enc, val)
  end

  def webhook_secret
    read_ciphered_attribute(:webhook_secret_enc)
  end

  def webhook_secret=(val)
    write_ciphered_attribute(:webhook_secret_enc, val)
  end

  # Validations
  validates :repository_id, presence: true, uniqueness: true
  validates :remote_url,    presence: true, length: { maximum: 512 }
  validates :auth_type,     inclusion: { in: AUTH_TYPES }
  validates :poll_cron,     presence: true, if: :poll_enabled?
  validates :webhook_token, presence: true, uniqueness: true

  validate :validate_remote_url_format
  validate :validate_cron_expression, if: -> { poll_enabled? && poll_cron.present? }
  validate :validate_safe_local_path,  if: -> { local_path.present? }

  # Safe attributes (mass-assignable)
  safe_attributes(
    'remote_url',
    'auth_type',
    'ssh_key_filename',
    'poll_enabled',
    'poll_cron',
    'webhook_enabled'
  )

  safe_attributes(
    'repository_id',
    if: lambda { |config, _user| config.new_record? }
  )

  # Callbacks
  before_validation :generate_webhook_token, on: :create
  before_save       :compute_local_path

  after_save    :reschedule_sync_job
  after_destroy :unschedule_sync_job
  after_destroy :cleanup_ssh_key_file
  after_destroy :cleanup_local_mirror

  # Scopes
  scope :poll_enabled,   -> { where(poll_enabled: true) }
  scope :stale,          -> { where(syncing: true).where('sync_started_at < ?', 1.hour.ago) }
  scope :with_project,   -> { includes(repository: :project) }

  # -----------------------------------------------------------------------
  # Public helpers
  # -----------------------------------------------------------------------

  def project
    repository&.project
  end

  def mirrored?
    local_path.present?
  end

  def stale_sync?
    syncing? && sync_started_at.present? && sync_started_at < 1.hour.ago
  end

  def webhook_url
    return nil unless webhook_token.present?

    Rails.application.routes.url_helpers.git_mirror_webhook_url(
      token: webhook_token,
      host:  Setting.host_name,
      protocol: Setting.protocol
    )
  end

  def last_sync_log
    sync_logs.order(started_at: :desc).first
  end

  # Reset a stale syncing flag so next run can proceed
  def reset_stale_sync!
    update_columns(syncing: false, sync_started_at: nil) if stale_sync?
  end

  # -----------------------------------------------------------------------
  # Private
  # -----------------------------------------------------------------------
  private

  def generate_webhook_token
    self.webhook_token ||= SecureRandom.urlsafe_base64(32)
  end

  def compute_local_path
    return if repository.nil?
    return if local_path.present? && !new_record?  # don't change after initial set

    proj_id  = repository.project&.identifier.presence || "project_#{repository.project_id}"
    repo_id  = repository.identifier.presence || "repo_#{repository.id}"
    base     = self.class.base_dir

    # Sanitize path components — allow only [a-z0-9\-_.]
    safe_proj = proj_id.gsub(/[^a-z0-9\-_.]/, '_').downcase
    safe_repo = repo_id.gsub(/[^a-z0-9\-_.]/, '_').downcase

    self.local_path = File.join(base, safe_proj, "#{safe_repo}.git")
  end

  def validate_remote_url_format
    return if remote_url.blank?

    # Accept SSH URLs (git@host:path) and HTTPS URLs
    ssh_pattern   = /\Agit@[a-zA-Z0-9.\-]+:[a-zA-Z0-9\/\-_.]+\.git\z/
    https_pattern = /\Ahttps?:\/\/[a-zA-Z0-9.\-]+(:[0-9]+)?\/[^\s]+\z/
    ssh_scp_alt   = /\Assh:\/\/[a-zA-Z0-9.\-]+(:[0-9]+)?\/[^\s]+\z/

    unless remote_url.match?(ssh_pattern) ||
           remote_url.match?(https_pattern) ||
           remote_url.match?(ssh_scp_alt)
      errors.add(:remote_url, :invalid)
    end
  end

  def validate_cron_expression
    require 'rufus-scheduler'
    Rufus::Scheduler.parse(poll_cron)
  rescue ArgumentError, Rufus::Scheduler::NotFound
    errors.add(:poll_cron, :invalid)
  end

  def validate_safe_local_path
    base = self.class.base_dir
    unless local_path.start_with?(base)
      errors.add(:local_path, 'must be within the configured mirror base directory')
    end
  end

  def reschedule_sync_job
    RedmineGitMirror::Services::Scheduler.schedule(self)
  end

  def unschedule_sync_job
    RedmineGitMirror::Services::Scheduler.unschedule(self)
  end

  def cleanup_ssh_key_file
    return unless auth_type == 'ssh_key' && ssh_key_filename.present?

    RedmineGitMirror::Services::CredentialManager.new(self).delete_ssh_key
  rescue StandardError => e
    Rails.logger.error "[RedmineGitMirror] Failed to delete SSH key #{ssh_key_filename}: #{e.message}"
  end

  def cleanup_local_mirror
    return if local_path.blank?
    return unless local_path.start_with?(self.class.base_dir)  # safety guard

    FileUtils.rm_rf(local_path)
    Rails.logger.info "[RedmineGitMirror] Removed local mirror: #{local_path}"
  rescue StandardError => e
    Rails.logger.error "[RedmineGitMirror] Failed to remove mirror at #{local_path}: #{e.message}"
  end

  # -----------------------------------------------------------------------
  # Class methods
  # -----------------------------------------------------------------------
  def self.base_dir
    configured = Setting.plugin_redmine_git_mirror['git_mirror_base_dir'].presence
    configured || Rails.root.join('repositories', 'redmine_git_mirror').to_s
  end
end
