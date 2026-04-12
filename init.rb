require 'redmine'

Redmine::Plugin.register :redmine_git_mirror do
  name        'Redmine Git Mirror'
  author      'ibaou'
  description 'Automatic Git repository mirroring with credential management, polling, and webhook support'
  version     '1.0.0'
  url         'https://github.com/ibaou-dev/redmine_git_mirror'
  author_url  'https://github.com/ibaou-dev'

  requires_redmine version_or_higher: '5.0'

  settings default: {
    'git_mirror_base_dir' => ''
  }, partial: 'settings/redmine_git_mirror_settings'

  project_module :redmine_git_mirror do
    permission :view_git_mirror_sync_logs,
               { git_mirror_sync_logs: [:index, :show] },
               read: true
    permission :manage_git_mirror,
               { git_mirror_configs: [:new, :create, :edit, :update, :destroy, :confirm_destroy, :trigger_sync] },
               require: :member
  end

  menu :admin_menu,
       :redmine_git_mirror,
       { controller: 'git_mirror_admin', action: 'index' },
       caption:  'Git Mirror',
       html:     { class: 'icon icon-repository' },
       last:     true
end

# Services (lib/ is not autoloaded — must be required explicitly)
require_relative 'lib/redmine_git_mirror/services/disk_guard'
require_relative 'lib/redmine_git_mirror/services/credential_manager'
require_relative 'lib/redmine_git_mirror/services/webhook_verifier'
require_relative 'lib/redmine_git_mirror/services/mirror_sync_service'
require_relative 'lib/redmine_git_mirror/services/scheduler'

# Hooks
require_relative 'lib/redmine_git_mirror/hooks/view_repositories_show_contextual_hook'
require_relative 'lib/redmine_git_mirror/hooks/view_layouts_base_html_head_hook'

# Patches
require_relative 'lib/redmine_git_mirror/patches/repository_git_patch'
require_relative 'lib/redmine_git_mirror/patches/projects_helper_patch'

# init.rb is loaded inside Redmine::PluginLoader's to_prepare block, so patches
# applied here run before each request (development) or once at boot (production).
Repository::Git.send(:include, RedmineGitMirror::Patches::RepositoryGitPatch)   unless Repository::Git.include?(RedmineGitMirror::Patches::RepositoryGitPatch)
ProjectsHelper.send(:include, RedmineGitMirror::Patches::ProjectsHelperPatch)   unless ProjectsHelper.include?(RedmineGitMirror::Patches::ProjectsHelperPatch)

Rails.application.config.after_initialize do
  next if Rails.env.test?
  next unless defined?(GitMirrorConfig) && GitMirrorConfig.table_exists?

  RedmineGitMirror::Services::Scheduler.reschedule_all
end
