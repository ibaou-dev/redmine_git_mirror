class GitMirrorWebhookController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :check_if_login_required

  before_action :find_config_by_token
  before_action :check_webhook_enabled
  before_action :rate_limit!

  def receive
    verifier = RedmineGitMirror::Services::WebhookVerifier.new(@config, request)

    begin
      verifier.verify!
    rescue RedmineGitMirror::Services::WebhookVerifier::ReplayAttackError => e
      render json: { error: 'Duplicate delivery' }, status: :conflict
      return
    rescue RedmineGitMirror::Services::WebhookVerifier::VerificationError => e
      render json: { error: 'Signature verification failed' }, status: :unauthorized
      return
    end

    # Record delivery UUID to prevent replay attacks
    GitMirrorWebhookDelivery.record!(@config.id, verifier.delivery_uuid) if verifier.delivery_uuid

    # Spawn background sync — respond immediately
    config_id = @config.id
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        cfg = GitMirrorConfig.find_by(id: config_id)
        RedmineGitMirror::Services::MirrorSyncService
          .new(cfg, trigger_type: 'webhook')
          .call if cfg
      end
    end

    render json: { status: 'queued' }, status: :ok
  end

  # -----------------------------------------------------------------------
  private
  # -----------------------------------------------------------------------

  def find_config_by_token
    token   = params[:token].to_s
    @config = GitMirrorConfig.find_by(webhook_token: token)
    render json: { error: 'Not found' }, status: :not_found unless @config
  end

  def check_webhook_enabled
    unless @config&.webhook_enabled?
      render json: { error: 'Webhook not enabled for this repository' }, status: :forbidden
    end
  end

  def rate_limit!
    key   = "redmine_git_mirror:webhook_rate:#{@config.id}:#{request.remote_ip}"
    count = Rails.cache.increment(key, 1, expires_in: 1.minute)
    return if count.nil?  # cache store doesn't support increment — skip rate limiting

    if count > 60
      render json: { error: 'Rate limit exceeded' }, status: :too_many_requests
    end
  end
end
