require File.expand_path('../../test_helper', __FILE__)

class GitMirrorConfigTest < ActiveSupport::TestCase
  def setup
    # Use an existing Redmine test project + Git repository if available,
    # or stub the associations
    @project    = Project.find(1) rescue Project.new(id: 1, identifier: 'testproject')
    @repository = Repository::Git.new(
      project:    @project,
      url:        '/tmp/test_repo.git',
      identifier: 'main-repo'
    )
    @repository.id = 1

    @config = GitMirrorConfig.new(
      repository:   @repository,
      remote_url:   'git@github.com:org/repo.git',
      auth_type:    'none',
      poll_enabled: true,
      poll_cron:    '*/15 * * * *'
    )
  end

  # ---------------------------------------------------------------------------
  # Validations
  # ---------------------------------------------------------------------------

  test 'valid with minimal attributes' do
    @config.stubs(:repository).returns(@repository)
    # Should be valid with SSH URL
    assert @config.valid?, @config.errors.full_messages.inspect
  end

  test 'requires remote_url' do
    @config.remote_url = ''
    @config.valid?
    assert_includes @config.errors[:remote_url], :blank.to_s
  end

  test 'accepts git@ SSH URL' do
    @config.remote_url = 'git@github.com:org/repo.git'
    @config.valid?
    assert_empty @config.errors[:remote_url]
  end

  test 'accepts https URL' do
    @config.remote_url = 'https://github.com/org/repo.git'
    @config.valid?
    assert_empty @config.errors[:remote_url]
  end

  test 'accepts ssh:// URL' do
    @config.remote_url = 'ssh://git@gitlab.com/org/repo.git'
    @config.valid?
    assert_empty @config.errors[:remote_url]
  end

  test 'rejects invalid URL' do
    @config.remote_url = 'not-a-url'
    @config.valid?
    assert_includes @config.errors[:remote_url], I18n.t('errors.messages.invalid')
  end

  test 'validates auth_type inclusion' do
    @config.auth_type = 'ftp'
    @config.valid?
    assert @config.errors[:auth_type].any?
  end

  test 'validates cron expression when poll_enabled' do
    @config.poll_enabled = true
    @config.poll_cron    = 'not-a-cron'
    @config.valid?
    assert @config.errors[:poll_cron].any?
  end

  test 'skips cron validation when poll disabled' do
    @config.poll_enabled = false
    @config.poll_cron    = 'not-a-cron'
    @config.valid?
    assert_empty @config.errors[:poll_cron]
  end

  # ---------------------------------------------------------------------------
  # Encrypted attribute round-trips
  # ---------------------------------------------------------------------------

  test 'access_token round-trips through ciphering' do
    secret = 'ghp_SuperSecretToken12345'
    @config.access_token = secret
    # The enc column should not equal the plaintext
    assert_not_equal secret, @config.access_token_enc.to_s
    assert_equal secret, @config.access_token
  end

  test 'password round-trips through ciphering' do
    pwd = 's3cr3t_p@ssw0rd'
    @config.password = pwd
    assert_not_equal pwd, @config.password_enc.to_s
    assert_equal pwd, @config.password
  end

  test 'webhook_secret round-trips through ciphering' do
    secret = 'webhook-hmac-secret-xyz'
    @config.webhook_secret = secret
    assert_not_equal secret, @config.webhook_secret_enc.to_s
    assert_equal secret, @config.webhook_secret
  end

  # ---------------------------------------------------------------------------
  # Webhook token generation
  # ---------------------------------------------------------------------------

  test 'generates webhook_token on new record' do
    config = GitMirrorConfig.new
    config.send(:generate_webhook_token)
    assert config.webhook_token.present?
    assert config.webhook_token.length >= 20
  end

  test 'webhook_token is URL-safe' do
    10.times do
      config = GitMirrorConfig.new
      config.send(:generate_webhook_token)
      assert_match(/\A[A-Za-z0-9_\-]+\z/, config.webhook_token)
    end
  end

  # ---------------------------------------------------------------------------
  # Local path computation
  # ---------------------------------------------------------------------------

  test 'compute_local_path produces path under base_dir' do
    @config.send(:compute_local_path)
    assert @config.local_path.start_with?(GitMirrorConfig.base_dir),
           "Expected #{@config.local_path} to start with #{GitMirrorConfig.base_dir}"
  end

  test 'compute_local_path sanitizes project/repo identifiers' do
    @project.identifier    = 'My Project!'
    @repository.identifier = 'repo../etc/passwd'
    @config.send(:compute_local_path)
    # Path components must not contain shell-dangerous chars
    refute @config.local_path.include?('..')
    refute @config.local_path.include?('!')
  end

  # ---------------------------------------------------------------------------
  # Path traversal prevention
  # ---------------------------------------------------------------------------

  test 'validate_safe_local_path rejects path outside base_dir' do
    @config.local_path = '/etc/cron.d/malicious.git'
    @config.valid?
    assert @config.errors[:local_path].any?
  end

  test 'validate_safe_local_path accepts path inside base_dir' do
    @config.local_path = File.join(GitMirrorConfig.base_dir, 'proj', 'repo.git')
    @config.valid?
    assert_empty @config.errors[:local_path]
  end

  # ---------------------------------------------------------------------------
  # Helper methods
  # ---------------------------------------------------------------------------

  test 'stale_sync? returns true when syncing for over 1 hour' do
    @config.syncing         = true
    @config.sync_started_at = 2.hours.ago
    assert @config.stale_sync?
  end

  test 'stale_sync? returns false when syncing is recent' do
    @config.syncing         = true
    @config.sync_started_at = 5.minutes.ago
    refute @config.stale_sync?
  end

  test 'stale_sync? returns false when not syncing' do
    @config.syncing = false
    refute @config.stale_sync?
  end
end
