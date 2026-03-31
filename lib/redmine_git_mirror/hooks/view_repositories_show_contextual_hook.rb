module RedmineGitMirror
  module Hooks
    class ViewRepositoriesShowContextualHook < Redmine::Hook::ViewListener
      render_on :view_repositories_show_contextual,
                partial: 'hooks/redmine_git_mirror/view_repositories_show_contextual'
    end
  end
end
