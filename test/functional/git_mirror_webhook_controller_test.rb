require File.expand_path('../../test_helper', __FILE__)

class GitMirrorWebhookControllerTest < ActionDispatch::IntegrationTest
  def setup
    @secret = 'test-webhook-secret'
    @body   = '{"ref":"refs/heads/main"}'

    @config = GitMirrorConfig.new(
      remote_url:      'git@github.com:org/repo.git',
      auth_type:       'none',
      webhook_enabled: true,
      webhook_token:   'test-token-abc123def456xyz'
    )
    @config.webhook_secret = @secret
    @config.stubs(:save).returns(true)
    GitMirrorConfig.stubs(:find_by).with(webhook_token: 'test-token-abc123def456xyz').returns(@config)
    GitMirrorConfig.stubs(:find_by).with(webhook_token: 'invalid-token').returns(nil)
  end

  def github_signature(secret, body)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
  end

  test 'returns 404 for unknown webhook token' do
    post '/git_mirror/webhook/invalid-token',
         headers: { 'X-GitHub-Event' => 'push' },
         params:  @body,
         as:      :json
    assert_response :not_found
  end

  test 'returns 401 for invalid GitHub signature' do
    GitMirrorWebhookDelivery.stubs(:seen?).returns(false)
    RedmineGitMirror::Services::MirrorSyncService.stubs(:new).returns(stub(call: nil))

    post "/git_mirror/webhook/#{@config.webhook_token}",
         headers: {
           'X-GitHub-Event'      => 'push',
           'X-Hub-Signature-256' => 'sha256=badhash',
           'X-GitHub-Delivery'   => 'delivery-401'
         },
         params:  @body,
         as:      :json
    assert_response :unauthorized
  end

  test 'returns 200 for valid GitHub webhook' do
    GitMirrorWebhookDelivery.stubs(:seen?).returns(false)
    GitMirrorWebhookDelivery.stubs(:record!).returns(nil)
    RedmineGitMirror::Services::MirrorSyncService.stubs(:new).returns(stub(call: nil))

    post "/git_mirror/webhook/#{@config.webhook_token}",
         headers: {
           'X-GitHub-Event'      => 'push',
           'X-Hub-Signature-256' => github_signature(@secret, @body),
           'X-GitHub-Delivery'   => 'delivery-200-valid'
         },
         params:  @body,
         as:      :json
    assert_response :ok
    json = JSON.parse(response.body)
    assert_equal 'queued', json['status']
  end

  test 'returns 409 for replayed delivery UUID' do
    GitMirrorWebhookDelivery.stubs(:seen?).with('replay-uuid').returns(true)

    post "/git_mirror/webhook/#{@config.webhook_token}",
         headers: {
           'X-GitHub-Event'      => 'push',
           'X-Hub-Signature-256' => github_signature(@secret, @body),
           'X-GitHub-Delivery'   => 'replay-uuid'
         },
         params:  @body,
         as:      :json
    assert_response :conflict
  end

  test 'returns 403 when webhook disabled' do
    @config.webhook_enabled = false

    post "/git_mirror/webhook/#{@config.webhook_token}",
         headers: { 'X-GitHub-Event' => 'push' },
         params:  @body,
         as:      :json
    assert_response :forbidden
  end
end
