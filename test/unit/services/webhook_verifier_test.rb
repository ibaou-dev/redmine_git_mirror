require File.expand_path('../../../test_helper', __FILE__)

class WebhookVerifierTest < ActiveSupport::TestCase
  def make_request(headers: {}, body: '{}')
    req = ActionDispatch::TestRequest.create
    req.env['rack.input'] = StringIO.new(body)
    headers.each do |k, v|
      rack_key = "HTTP_#{k.upcase.tr('-', '_')}"
      req.env[rack_key] = v
    end
    req
  end

  def make_config(secret: nil, webhook_enabled: true)
    config = GitMirrorConfig.new(
      remote_url:      'git@github.com:org/repo.git',
      auth_type:       'none',
      webhook_enabled: webhook_enabled
    )
    config.webhook_secret = secret if secret
    config
  end

  def github_sig(secret, body)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
  end

  # ---------------------------------------------------------------------------
  # Platform detection
  # ---------------------------------------------------------------------------

  test 'detects GitHub from X-GitHub-Event header' do
    config  = make_config
    request = make_request(headers: { 'X-GitHub-Event' => 'push' })
    v = RedmineGitMirror::Services::WebhookVerifier.new(config, request)
    assert_equal :github, v.send(:detect_platform)
  end

  test 'detects GitLab from X-Gitlab-Event header' do
    config  = make_config
    request = make_request(headers: { 'X-Gitlab-Event' => 'Push Hook' })
    v = RedmineGitMirror::Services::WebhookVerifier.new(config, request)
    assert_equal :gitlab, v.send(:detect_platform)
  end

  test 'detects Bitbucket from X-Event-Key header' do
    config  = make_config
    request = make_request(headers: { 'X-Event-Key' => 'repo:push' })
    v = RedmineGitMirror::Services::WebhookVerifier.new(config, request)
    assert_equal :bitbucket, v.send(:detect_platform)
  end

  # ---------------------------------------------------------------------------
  # GitHub HMAC verification
  # ---------------------------------------------------------------------------

  test 'GitHub: valid signature passes' do
    secret  = 'my-webhook-secret'
    body    = '{"ref":"refs/heads/main"}'
    config  = make_config(secret: secret)
    request = make_request(
      headers: {
        'X-GitHub-Event'      => 'push',
        'X-Hub-Signature-256' => github_sig(secret, body),
        'X-GitHub-Delivery'   => 'unique-delivery-id-1'
      },
      body: body
    )
    v = RedmineGitMirror::Services::WebhookVerifier.new(config, request)
    # Mock replay check to return false (not seen)
    GitMirrorWebhookDelivery.stubs(:seen?).returns(false)
    assert_nothing_raised { v.verify! }
  end

  test 'GitHub: tampered body fails' do
    secret  = 'my-webhook-secret'
    body    = '{"ref":"refs/heads/main"}'
    config  = make_config(secret: secret)
    request = make_request(
      headers: {
        'X-GitHub-Event'      => 'push',
        'X-Hub-Signature-256' => github_sig(secret, body),
        'X-GitHub-Delivery'   => 'unique-delivery-id-2'
      },
      body: '{"ref":"refs/heads/attacker"}'  # tampered
    )
    v = RedmineGitMirror::Services::WebhookVerifier.new(config, request)
    GitMirrorWebhookDelivery.stubs(:seen?).returns(false)
    assert_raises(RedmineGitMirror::Services::WebhookVerifier::InvalidSignatureError) { v.verify! }
  end

  # ---------------------------------------------------------------------------
  # GitLab token verification
  # ---------------------------------------------------------------------------

  test 'GitLab: valid token passes' do
    secret  = 'gitlab-secret-token'
    config  = make_config(secret: secret)
    request = make_request(
      headers: {
        'X-Gitlab-Event'    => 'Push Hook',
        'X-Gitlab-Token'    => secret,
        'X-Gitlab-Event-UUID' => 'gitlab-delivery-uuid-1'
      }
    )
    v = RedmineGitMirror::Services::WebhookVerifier.new(config, request)
    GitMirrorWebhookDelivery.stubs(:seen?).returns(false)
    assert_nothing_raised { v.verify! }
  end

  test 'GitLab: wrong token fails' do
    config  = make_config(secret: 'correct-token')
    request = make_request(
      headers: {
        'X-Gitlab-Event'      => 'Push Hook',
        'X-Gitlab-Token'      => 'wrong-token',
        'X-Gitlab-Event-UUID' => 'gitlab-delivery-uuid-2'
      }
    )
    v = RedmineGitMirror::Services::WebhookVerifier.new(config, request)
    GitMirrorWebhookDelivery.stubs(:seen?).returns(false)
    assert_raises(RedmineGitMirror::Services::WebhookVerifier::InvalidSignatureError) { v.verify! }
  end

  # ---------------------------------------------------------------------------
  # Replay attack prevention
  # ---------------------------------------------------------------------------

  test 'raises ReplayAttackError for duplicate delivery UUID' do
    config  = make_config
    request = make_request(
      headers: {
        'X-GitHub-Event'    => 'push',
        'X-GitHub-Delivery' => 'already-seen-uuid'
      }
    )
    v = RedmineGitMirror::Services::WebhookVerifier.new(config, request)
    GitMirrorWebhookDelivery.stubs(:seen?).with('already-seen-uuid').returns(true)
    assert_raises(RedmineGitMirror::Services::WebhookVerifier::ReplayAttackError) { v.verify! }
  end
end
