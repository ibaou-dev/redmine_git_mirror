require File.expand_path('../../test_helper', __FILE__)

class GitMirrorWebhookDeliveryTest < ActiveSupport::TestCase
  test 'seen? returns false for unknown uuid' do
    assert_equal false, GitMirrorWebhookDelivery.seen?('nonexistent-uuid-12345')
  end

  test 'seen? returns false for blank uuid' do
    assert_equal false, GitMirrorWebhookDelivery.seen?('')
    assert_equal false, GitMirrorWebhookDelivery.seen?(nil)
  end
end
