module RedmineGitMirror
  module Hooks
    class ViewLayoutsBaseHtmlHeadHook < Redmine::Hook::ViewListener
      render_on :view_layouts_base_html_head,
                partial: 'hooks/redmine_git_mirror/view_layouts_base_html_head'
    end
  end
end
