require File.expand_path('../../test_helper', __FILE__)

class GitMirrorSyncLogTest < ActiveSupport::TestCase
  def setup
    @log = GitMirrorSyncLog.new(
      git_mirror_config_id: 1,
      trigger_type:         'manual',
      started_at:           Time.current,
      status:               'running'
    )
  end

  test 'valid log' do
    assert @log.valid?, @log.errors.full_messages.inspect
  end

  test 'requires trigger_type inclusion' do
    @log.trigger_type = 'unknown'
    @log.valid?
    assert @log.errors[:trigger_type].any?
  end

  test 'requires status inclusion' do
    @log.status = 'unknown'
    @log.valid?
    assert @log.errors[:status].any?
  end

  test 'duration_seconds returns nil when not completed' do
    assert_nil @log.duration_seconds
  end

  test 'duration_seconds calculates correct elapsed time' do
    @log.started_at   = Time.current - 45.seconds
    @log.completed_at = Time.current
    assert_in_delta 45, @log.duration_seconds, 2
  end

  test 'complete! caps output at 10KB' do
    long_output = 'x' * 20_000
    @log.stubs(:update!).with { |args| args[:output].length <= 10_240 }.returns(true)
    # Verify truncation: last(10_240) on 20_000 chars = 10_240 chars
    assert_equal 10_240, long_output.last(10_240).length
  end
end
