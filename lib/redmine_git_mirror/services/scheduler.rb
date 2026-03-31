require 'rufus-scheduler'

module RedmineGitMirror
  module Services
    # Manages per-repository cron jobs using Rufus-Scheduler.
    #
    # One Rufus::Scheduler instance runs in a background thread per process.
    # Each GitMirrorConfig with poll_enabled=true gets one cron job tagged with
    # "git_mirror_<config_id>". CRUD callbacks on GitMirrorConfig automatically
    # call schedule/unschedule to keep jobs in sync.
    #
    # The scheduler is NOT started in test environment to prevent test pollution.
    module Scheduler
      JOB_TAG_PREFIX = 'git_mirror_'.freeze
      CLEANUP_CRON   = '0 * * * *'.freeze  # hourly webhook delivery cleanup

      module_function

      # Returns the singleton Rufus::Scheduler instance (lazy-initialised).
      def instance
        @instance ||= Rufus::Scheduler.new(
          max_work_threads: 4,
          on_error:         method(:handle_scheduler_error)
        )
      end

      # Schedule (or reschedule) a cron job for the given GitMirrorConfig.
      # Safe to call multiple times — replaces any existing job for this config.
      def schedule(config)
        return unless config.poll_enabled? && config.poll_cron.present?

        unschedule(config)  # remove stale job if any

        tag = job_tag(config)
        instance.cron(config.poll_cron, tag: tag) do
          safe_sync(config.id, 'scheduler')
        end

        Rails.logger.info "[RedmineGitMirror::Scheduler] Scheduled #{tag} (#{config.poll_cron})"
      rescue ArgumentError, Rufus::Scheduler::NotFound => e
        Rails.logger.error "[RedmineGitMirror::Scheduler] Invalid cron '#{config.poll_cron}' for config #{config.id}: #{e.message}"
      end

      # Remove the cron job for the given GitMirrorConfig (if it exists).
      def unschedule(config)
        tag = job_tag(config)
        jobs = instance.jobs(tag: tag)
        jobs.each(&:unschedule)
        Rails.logger.info "[RedmineGitMirror::Scheduler] Unscheduled #{tag}" if jobs.any?
      end

      # Load all active configs from the DB and (re)schedule their cron jobs.
      # Called once at application boot from init.rb after_initialize.
      def reschedule_all
        # Remove all existing mirror cron jobs
        instance.jobs(tag: JOB_TAG_PREFIX).each(&:unschedule)

        configs = GitMirrorConfig.poll_enabled.to_a
        configs.each { |cfg| schedule(cfg) }

        # Schedule the periodic cleanup job (idempotent)
        unless instance.jobs(tag: 'git_mirror_cleanup').any?
          instance.cron(CLEANUP_CRON, tag: 'git_mirror_cleanup') do
            GitMirrorWebhookDelivery.cleanup_old!
          rescue StandardError => e
            Rails.logger.error "[RedmineGitMirror::Scheduler] Cleanup error: #{e.message}"
          end
        end

        Rails.logger.info "[RedmineGitMirror::Scheduler] Scheduled #{configs.size} mirror job(s)"
      end

      # Shut down the scheduler gracefully (called on process exit if needed).
      def shutdown
        return unless @instance

        @instance.shutdown(:wait)
        @instance = nil
      end

      # -----------------------------------------------------------------------
      private
      # -----------------------------------------------------------------------

      def job_tag(config)
        "#{JOB_TAG_PREFIX}#{config.id}"
      end

      # Wraps a sync call with DB reload and error isolation.
      # Reloads the config from DB so we always use current credentials/settings.
      def safe_sync(config_id, trigger_type)
        config = GitMirrorConfig.find_by(id: config_id)
        unless config
          Rails.logger.warn "[RedmineGitMirror::Scheduler] Config #{config_id} not found — skipping"
          return
        end

        RedmineGitMirror::Services::MirrorSyncService
          .new(config, trigger_type: trigger_type)
          .call
      rescue StandardError => e
        Rails.logger.error "[RedmineGitMirror::Scheduler] Sync error for config #{config_id}: #{e.full_message}"
      end

      def handle_scheduler_error(job, error)
        Rails.logger.error "[RedmineGitMirror::Scheduler] Job #{job.tags.first} raised: #{error.full_message}"
      end
    end
  end
end
