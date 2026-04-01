class GitMirrorAdminController < ApplicationController
  layout 'admin'

  before_action :require_admin

  def index
    @configs = GitMirrorConfig
                 .includes(repository: :project)
                 .order('projects.name, repositories.identifier')
                 .all

    @stats = {
      total:    @configs.count,
      syncing:  @configs.count(&:syncing?),
      stale:    @configs.count(&:stale_sync?),
      failed:   @configs.count { |c| c.last_sync_status == 'failed' },
      success:  @configs.count { |c| c.last_sync_status == 'success' }
    }
  end
end
