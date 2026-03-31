module RedmineGitMirror
  module Patches
    module RepositoryGitPatch
      def self.included(base)
        base.class_eval do
          has_one :git_mirror_config,
                  class_name:  'GitMirrorConfig',
                  foreign_key: 'repository_id',
                  dependent:   :destroy
        end
      end
    end
  end
end
