class GitMirrorSyncLogsController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize

  def index
    scope = GitMirrorSyncLog
              .joins(git_mirror_config: :repository)
              .where(repositories: { project_id: @project.id })
              .recent

    if params[:git_mirror_config_id].present?
      scope = scope.where(git_mirror_config_id: params[:git_mirror_config_id])
      @config = GitMirrorConfig.find_by(id: params[:git_mirror_config_id])
    end

    scope = scope.where(status: params[:status]) if params[:status].present?

    @limit       = per_page_option
    @entry_count = scope.count
    @entry_pages = Redmine::Pagination::Paginator.new(@entry_count, @limit, params['page'])

    @logs = scope.limit(@limit).offset(@entry_pages.offset)
  end

  def show
    @log = GitMirrorSyncLog
             .joins(git_mirror_config: :repository)
             .where(repositories: { project_id: @project.id })
             .find(params[:id])
    @config = @log.git_mirror_config
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
