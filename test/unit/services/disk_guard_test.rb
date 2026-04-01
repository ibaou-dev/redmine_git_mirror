require File.expand_path('../../../test_helper', __FILE__)

class DiskGuardTest < ActiveSupport::TestCase
  include RedmineGitMirror::Services

  test 'check! passes when sufficient space available' do
    # /tmp should always have more than 1 byte free
    assert_nothing_raised do
      DiskGuard.check!('/tmp', min_bytes: 1)
    end
  end

  test 'check! raises InsufficientSpaceError when threshold too high' do
    assert_raises(DiskGuard::InsufficientSpaceError) do
      DiskGuard.check!('/tmp', min_bytes: 999_999_999_999_999)
    end
  end

  test 'check! walks up to existing parent directory' do
    # Non-existent path — should walk up to /tmp
    assert_nothing_raised do
      DiskGuard.check!('/tmp/nonexistent/deep/path', min_bytes: 1)
    end
  end
end
