module RedmineGitMirror
  module Patches
    module ProjectsHelperPatch
      def self.included(base)
        base.prepend(InstanceMethods)
      end

      module InstanceMethods
        def project_settings_tabs
          tabs = super
          if User.current.allowed_to?(:manage_git_mirror, @project)
            tabs << {
              name:    'git_mirror',
              action:  :manage_git_mirror,
              partial: 'git_mirror_configs/settings_tab',
              label:   :label_git_mirror
            }
          end
          tabs
        end
      end
    end
  end
end
