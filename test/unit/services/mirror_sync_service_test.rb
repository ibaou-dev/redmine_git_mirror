require File.expand_path('../../../test_helper', __FILE__)

class MirrorSyncServiceTest < ActiveSupport::TestCase
  def make_config(local_path: '/tmp/test-mirror.git', syncing: false, sync_started_at: nil)
    config = GitMirrorConfig.new(
      remote_url:   'git@github.com:org/repo.git',
      auth_type:    'none',
      local_path:   local_path
    )
    config.syncing         = syncing
    config.sync_started_at = sync_started_at
    config.stubs(:id).returns(42)
    config.stubs(:repository_id).returns(99)
    config.stubs(:update_columns).returns(true)
    config.stubs(:reset_stale_sync!).returns(nil)
    config.stubs(:stale_sync?).returns(false)
    config.stubs(:repository).returns(stub(fetch_changesets: nil, update_columns: nil))
    config
  end

  test 'returns :skipped when lock cannot be acquired' do
    config  = make_config
    service = RedmineGitMirror::Services::MirrorSyncService.new(config, trigger_type: 'manual')

    # Simulate lock already held
    service.stubs(:acquire_lock).returns(false)
    service.stubs(:release_lock).returns(nil)

    result = service.call
    assert_equal :skipped, result.status
  end

  test 'returns :failed after 3 retries' do
    config  = make_config
    service = RedmineGitMirror::Services::MirrorSyncService.new(config, trigger_type: 'scheduler')

    service.stubs(:acquire_lock).returns(true)
    service.stubs(:release_lock).returns(nil)
    service.stubs(:perform_git_operation).raises(RuntimeError, 'git: command not found')
    service.stubs(:sleep)  # skip delays in tests

    GitMirrorSyncLog.stubs(:create!).returns(stub(complete!: nil))

    result = service.call
    assert_equal :failed, result.status
    assert_match 'git: command not found', result.error_message
  end
end
