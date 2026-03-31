class GitMirrorConfigsController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize
  before_action :find_config,        only: [:edit, :update, :destroy, :trigger_sync]

  def new
    repository_id = params[:repository_id]
    @repository   = Repository.find_by(id: repository_id, project_id: @project.id)

    if @repository.nil? || !@repository.is_a?(Repository::Git)
      flash[:error] = 'Git Mirror can only be configured for Git repositories.'
      redirect_to settings_project_path(@project, tab: 'repositories')
      return
    end

    @config = GitMirrorConfig.new(repository_id: @repository.id)
  end

  def create
    repository_id = params.dig(:git_mirror_config, :repository_id)
    @repository   = Repository.find_by(id: repository_id, project_id: @project.id)

    if @repository.nil? || !@repository.is_a?(Repository::Git)
      flash[:error] = 'Invalid repository.'
      redirect_to settings_project_path(@project, tab: 'repositories')
      return
    end

    @config = GitMirrorConfig.new
    @config.safe_attributes = params[:git_mirror_config]
    @config.repository_id   = @repository.id

    creds = params[:git_mirror_config] || {}
    @config.access_token = creds[:access_token] if creds[:access_token].present?
    @config.password     = creds[:password]     if creds[:password].present?
    @config.username     = creds[:username]     if creds[:username].present?

    handle_ssh_key_upload

    if @config.save
      queue_initial_sync
      flash[:notice] = l(:notice_git_mirror_created)
      redirect_to settings_project_path(@project, tab: 'repositories')
    else
      render :new
    end
  end

  def edit
  end

  def update
    @config.safe_attributes = params[:git_mirror_config]

    creds = params[:git_mirror_config] || {}
    @config.access_token = creds[:access_token] if creds[:access_token].present?
    @config.password     = creds[:password]     if creds[:password].present?
    @config.username     = creds[:username]     if creds[:username].present?

    handle_ssh_key_upload
    handle_webhook_secret_update

    if @config.save
      flash[:notice] = l(:notice_git_mirror_updated)
      redirect_to settings_project_path(@project, tab: 'repositories')
    else
      @repository = @config.repository
      render :edit
    end
  end

  def destroy
    @config.destroy
    flash[:notice] = l(:notice_git_mirror_deleted)
    redirect_to settings_project_path(@project, tab: 'repositories')
  end

  def trigger_sync
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        RedmineGitMirror::Services::MirrorSyncService
          .new(@config, trigger_type: 'manual')
          .call
      end
    end
    flash[:notice] = l(:notice_git_mirror_sync_queued)
    redirect_to git_mirror_sync_logs_path(@project, git_mirror_config_id: @config.id)
  end

  # -----------------------------------------------------------------------
  private
  # -----------------------------------------------------------------------

  def find_config
    @config = GitMirrorConfig.find_by(id: params[:id])
    if @config.nil? || @config.repository.nil? || @config.repository.project_id != @project.id
      render_404
      return
    end
    @repository = @config.repository
  end

  def handle_ssh_key_upload
    key_material = params.dig(:git_mirror_config, :ssh_key_material).to_s.strip
    return if key_material.blank?

    manager  = RedmineGitMirror::Services::CredentialManager.new(@config)
    filename = manager.write_ssh_key(key_material)
    @config.ssh_key_filename = filename
  rescue StandardError => e
    @config.errors.add(:base, "SSH key upload failed: #{e.message}")
  end

  def handle_webhook_secret_update
    return unless params.dig(:git_mirror_config, :regenerate_webhook_secret) == '1'

    @config.webhook_secret = SecureRandom.hex(32)
  end

  def queue_initial_sync
    config_id = @config.id
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        cfg = GitMirrorConfig.find_by(id: config_id)
        RedmineGitMirror::Services::MirrorSyncService
          .new(cfg, trigger_type: 'manual')
          .call if cfg
      end
    end
  end
end
