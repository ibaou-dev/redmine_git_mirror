class GitMirrorConfigsController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize
  before_action :find_config, only: [:edit, :update, :destroy, :trigger_sync, :confirm_destroy]

  def new
    if params[:repository_id].present?
      # Link to an existing manually-added Git repository
      @repository = Repository.find_by(id: params[:repository_id], project_id: @project.id)
      if @repository.nil? || !@repository.is_a?(Repository::Git)
        flash[:error] = 'Invalid repository.'
        redirect_to settings_project_path(@project, tab: 'git_mirror') and return
      end
      @config = GitMirrorConfig.new(repository_id: @repository.id)
    else
      # Auto-create flow: no pre-existing repository needed
      @config = GitMirrorConfig.new
    end
  end

  def create
    @config = GitMirrorConfig.new
    @config.safe_attributes = params[:git_mirror_config]
    set_credentials(@config)
    handle_ssh_key_upload

    repository_id = params.dig(:git_mirror_config, :repository_id).presence
    success = false

    ActiveRecord::Base.transaction do
      if repository_id
        @repository = Repository.find_by(id: repository_id, project_id: @project.id)
        if @repository.nil? || !@repository.is_a?(Repository::Git)
          @config.errors.add(:base, 'Invalid repository.')
          raise ActiveRecord::Rollback
        end
      else
        @repository = auto_create_repository(@config.remote_url)
        unless @repository.persisted?
          @config.errors.add(:base, @repository.errors.full_messages.join(', '))
          raise ActiveRecord::Rollback
        end
      end

      @config.repository_id = @repository.id
      raise ActiveRecord::Rollback unless @config.save

      # Point repository URL at the local mirror path (may not exist yet — updated again after first sync)
      @repository.update_column(:url, @config.local_path) if @config.local_path.present?
      success = true
    end

    if success
      queue_initial_sync
      flash[:notice] = l(:notice_git_mirror_created)
      redirect_to settings_project_path(@project, tab: 'git_mirror')
    else
      render :new
    end
  end

  def edit
  end

  def update
    # Capture before safe_attributes overwrites the value
    url_changing = @config.remote_url != params.dig(:git_mirror_config, :remote_url).to_s

    @config.safe_attributes = params[:git_mirror_config]
    set_credentials(@config)
    handle_ssh_key_upload
    handle_webhook_secret_update

    if @config.save
      if url_changing && @config.local_path.present? && Dir.exist?(@config.local_path)
        FileUtils.rm_rf(@config.local_path)
        @config.update_columns(last_sync_at: nil, last_sync_status: 'pending', last_error_message: nil)
      end
      flash[:notice] = l(:notice_git_mirror_updated)
      redirect_to settings_project_path(@project, tab: 'git_mirror')
    else
      @repository = @config.repository
      render :edit
    end
  end

  def confirm_destroy
  end

  def destroy
    @config.destroy
    flash[:notice] = l(:notice_git_mirror_deleted)
    redirect_to settings_project_path(@project, tab: 'git_mirror')
  end

  def trigger_sync
    config_id = @config.id
    Thread.new do
      cfg = ActiveRecord::Base.connection_pool.with_connection { GitMirrorConfig.find_by(id: config_id) }
      RedmineGitMirror::Services::MirrorSyncService.new(cfg, trigger_type: 'manual').call if cfg
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

  def set_credentials(config)
    creds = params[:git_mirror_config] || {}
    config.access_token = creds[:access_token] if creds[:access_token].present?
    config.password     = creds[:password]     if creds[:password].present?
    config.username     = creds[:username]     if creds[:username].present?
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
      cfg = ActiveRecord::Base.connection_pool.with_connection { GitMirrorConfig.find_by(id: config_id) }
      RedmineGitMirror::Services::MirrorSyncService.new(cfg, trigger_type: 'manual').call if cfg
    end
  end

  # Auto-creates a Repository::Git linked to this project, deriving an identifier
  # from the remote URL. Used when no pre-existing repository is being linked.
  def auto_create_repository(remote_url)
    identifier = derive_identifier_from_url(remote_url)
    Repository::Git.create(
      project_id: @project.id,
      url:        remote_url.to_s,   # placeholder; overwritten after config saves
      identifier: identifier,
      is_default: @project.repositories.empty?
    )
  end

  def derive_identifier_from_url(url)
    # Extract the last path component, strip .git, normalise to [a-z0-9-]
    raw  = url.to_s.split('/').last.to_s.sub(/\.git\z/, '')
    name = raw.downcase.gsub(/[^a-z0-9\-]/, '-').squeeze('-').gsub(/\A-+|-+\z/, '')
    name = 'mirror' if name.blank?

    # Ensure uniqueness within project
    base = name
    n    = 1
    while @project.repositories.exists?(identifier: name)
      name = "#{base}-#{n}"
      n   += 1
    end
    name
  end
end
