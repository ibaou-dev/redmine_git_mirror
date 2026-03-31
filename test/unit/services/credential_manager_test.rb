require File.expand_path('../../../test_helper', __FILE__)

class CredentialManagerTest < ActiveSupport::TestCase
  SAMPLE_KEY = <<~KEY
    -----BEGIN OPENSSH PRIVATE KEY-----
    b3BlbnNzaC1rZXktdjEAAAAA
    -----END OPENSSH PRIVATE KEY-----
  KEY

  def make_config(auth_type: 'ssh_key', ssh_key_filename: nil)
    config = GitMirrorConfig.new(
      remote_url: 'git@github.com:org/repo.git',
      auth_type:  auth_type
    )
    config.ssh_key_filename = ssh_key_filename if ssh_key_filename
    config
  end

  def teardown
    # Clean up any test key files
    dir = File.join(Rails.root, 'tmp', 'redmine_git_mirror', 'ssh_keys')
    Dir.glob(File.join(dir, 'test-*')).each { |f| File.delete(f) rescue nil }
  end

  test 'git_env returns GIT_SSH_COMMAND for ssh_key auth' do
    filename = SecureRandom.uuid
    config   = make_config(auth_type: 'ssh_key', ssh_key_filename: filename)
    manager  = RedmineGitMirror::Services::CredentialManager.new(config)

    # Create a dummy key file so path check passes
    FileUtils.mkdir_p(File.join(Rails.root, 'tmp', 'redmine_git_mirror', 'ssh_keys'))
    File.write(manager.ssh_key_path(filename), SAMPLE_KEY, perm: 0o600)

    env = manager.git_env
    assert_includes env.keys, 'GIT_SSH_COMMAND'
    assert_includes env['GIT_SSH_COMMAND'], '-i '
    assert_includes env['GIT_SSH_COMMAND'], 'StrictHostKeyChecking=no'
  ensure
    File.delete(manager.ssh_key_path(filename)) rescue nil
  end

  test 'git_env returns GIT_TERMINAL_PROMPT=0 for none auth' do
    config  = make_config(auth_type: 'none')
    manager = RedmineGitMirror::Services::CredentialManager.new(config)
    env     = manager.git_env
    assert_equal '0', env['GIT_TERMINAL_PROMPT']
  end

  test 'authenticated_remote_url embeds token in HTTPS URL' do
    config = make_config(auth_type: 'token')
    config.access_token = 'ghp_token123'
    config.remote_url   = 'https://github.com/org/repo.git'
    manager = RedmineGitMirror::Services::CredentialManager.new(config)

    url = manager.authenticated_remote_url
    assert_includes url, 'ghp_token123'
    assert_includes url, 'x-access-token'
    assert url.start_with?('https://')
  end

  test 'authenticated_remote_url does not modify SSH URL for token auth' do
    config = make_config(auth_type: 'ssh_key')
    config.remote_url = 'git@github.com:org/repo.git'
    manager = RedmineGitMirror::Services::CredentialManager.new(config)
    assert_equal 'git@github.com:org/repo.git', manager.authenticated_remote_url
  end

  test 'ssh_key_path rejects filenames with path separators' do
    config  = make_config(ssh_key_filename: '../../../etc/passwd')
    manager = RedmineGitMirror::Services::CredentialManager.new(config)
    assert_raises(ArgumentError) { manager.ssh_key_path }
  end

  test 'write_ssh_key creates file with mode 0600' do
    config   = make_config(auth_type: 'ssh_key')
    manager  = RedmineGitMirror::Services::CredentialManager.new(config)
    filename = SecureRandom.uuid
    config.ssh_key_filename = filename

    manager.write_ssh_key(SAMPLE_KEY)
    path = manager.ssh_key_path(filename)

    assert File.exist?(path)
    assert_equal 0o100600, File.stat(path).mode, 'Key file must have mode 0600'
  ensure
    manager.delete_ssh_key rescue nil
  end
end
