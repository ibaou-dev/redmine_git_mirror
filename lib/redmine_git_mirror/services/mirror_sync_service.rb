require 'open3'
require 'fileutils'

module RedmineGitMirror
  module Services
    # Performs a git clone or fetch for a given GitMirrorConfig.
    #
    # Responsibilities:
    #   - Acquire a per-repository lock (prevents double-sync)
    #   - Check disk space before operating
    #   - Clone bare repo on first run, fetch --all --prune on subsequent runs
    #   - Retry transient failures (3 attempts, exponential backoff)
    #   - Record a GitMirrorSyncLog entry for each run
    #   - Call repository.fetch_changesets to import commits into Redmine
    #   - Update GitMirrorConfig sync state columns
    class MirrorSyncService
      RETRY_DELAYS  = [5, 30, 120].freeze     # seconds between retry attempts
      OUTPUT_MAX    = 10 * 1024               # cap git output stored in DB at 10 KB
      LOCK_TIMEOUT  = 1.hour                  # after this, a sync is considered stale

      SyncResult = Struct.new(:status, :commits_fetched, :output, :error_message, keyword_init: true)

      def initialize(config, trigger_type:)
        @config       = config
        @trigger_type = trigger_type
        @credential   = CredentialManager.new(config)
        @lock_file    = nil
      end

      # Entry point. Returns a SyncResult.
      def call
        # Reset stale lock from a previous dead process
        @config.reset_stale_sync! if @config.stale_sync?

        unless acquire_lock
          Rails.logger.info "[RedmineGitMirror] Skipping sync for repo #{@config.repository_id} — lock held"
          return SyncResult.new(status: :skipped, commits_fetched: 0, output: nil, error_message: nil)
        end

        log = GitMirrorSyncLog.create!(
          git_mirror_config_id: @config.id,
          trigger_type:         @trigger_type.to_s,
          started_at:           Time.current,
          status:               'running'
        )

        @config.update_columns(syncing: true, sync_started_at: Time.current)

        result = perform_with_retry
        update_config_after_sync(result)
        log.complete!(
          status:          result.status == :success ? 'success' : 'failed',
          commits_fetched: result.commits_fetched,
          output:          result.output,
          error_message:   result.error_message
        )

        result
      rescue StandardError => e
        # Catch unexpected errors so the lock is always released
        Rails.logger.error "[RedmineGitMirror] Unexpected error during sync: #{e.full_message}"
        SyncResult.new(status: :error, commits_fetched: 0, output: nil, error_message: e.message)
      ensure
        release_lock
        @config.update_columns(syncing: false)
      end

      # -----------------------------------------------------------------------
      private
      # -----------------------------------------------------------------------

      def perform_with_retry
        last_error  = nil
        total_output = ''

        RETRY_DELAYS.each_with_index do |delay, attempt|
          begin
            result = perform_git_operation
            # If we get here, git operation succeeded
            import_changesets(result)
            return result
          rescue StandardError => e
            last_error   = e
            total_output += "\n[Attempt #{attempt + 1} failed: #{e.message}]"
            Rails.logger.warn "[RedmineGitMirror] Sync attempt #{attempt + 1} failed: #{e.message}"
            sleep(delay) unless attempt == RETRY_DELAYS.length - 1
          end
        end

        # All attempts exhausted
        SyncResult.new(
          status:          :failed,
          commits_fetched: 0,
          output:          total_output.last(OUTPUT_MAX),
          error_message:   last_error&.message
        )
      end

      def perform_git_operation
        local_path = @config.local_path
        raise 'local_path is not set on config' if local_path.blank?

        if Dir.exist?(local_path)
          fetch_existing_mirror(local_path)
        else
          clone_new_mirror(local_path)
        end
      end

      def clone_new_mirror(local_path)
        DiskGuard.check!(local_path, min_bytes: DiskGuard::MIN_BYTES_FOR_CLONE)

        FileUtils.mkdir_p(File.dirname(local_path))

        remote_url = @credential.authenticated_remote_url
        cmd        = ['git', 'clone', '--bare', '--mirror', remote_url, local_path]
        env        = @credential.git_env

        output, error, success = run_git(env, cmd)

        unless success
          raise "git clone failed:\n#{error}"
        end

        # Update the repository record's url to point to the new local mirror
        @config.repository.update_columns(url: local_path)

        SyncResult.new(
          status:          :success,
          commits_fetched: count_all_commits(local_path),
          output:          "#{output}\n#{error}".last(OUTPUT_MAX),
          error_message:   nil
        )
      end

      def fetch_existing_mirror(local_path)
        DiskGuard.check!(local_path, min_bytes: DiskGuard::MIN_BYTES_FOR_FETCH)

        before_count = count_all_commits(local_path)
        remote_url   = @credential.authenticated_remote_url
        env          = @credential.git_env

        # Update the remote URL in the bare repo (handles token rotation etc.)
        run_git(env, ['git', '--git-dir', local_path, 'remote', 'set-url', 'origin', remote_url])

        cmd = ['git', '--git-dir', local_path, 'fetch', '--all', '--prune', '--tags']
        output, error, success = run_git(env, cmd)

        unless success
          raise "git fetch failed:\n#{error}"
        end

        after_count = count_all_commits(local_path)

        SyncResult.new(
          status:          :success,
          commits_fetched: [after_count - before_count, 0].max,
          output:          "#{output}\n#{error}".last(OUTPUT_MAX),
          error_message:   nil
        )
      end

      def import_changesets(result)
        return unless result.status == :success

        @config.repository.fetch_changesets
      rescue Redmine::Scm::Adapters::CommandFailed => e
        # fetch_changesets failing is non-fatal — we successfully mirrored
        Rails.logger.warn "[RedmineGitMirror] fetch_changesets raised: #{e.message}"
        result.error_message = "Mirror succeeded but changeset import failed: #{e.message}"
      rescue StandardError => e
        Rails.logger.error "[RedmineGitMirror] fetch_changesets unexpected error: #{e.message}"
        result.error_message = "Mirror succeeded but changeset import error: #{e.message}"
      end

      def update_config_after_sync(result)
        attrs = {
          last_sync_at:     Time.current,
          last_sync_status: result.status.to_s
        }
        attrs[:last_error_message] = result.error_message if result.error_message.present?
        @config.update_columns(**attrs)
      end

      # -----------------------------------------------------------------------
      # Locking
      # -----------------------------------------------------------------------

      def acquire_lock
        if postgresql?
          acquire_pg_lock
        else
          acquire_file_lock
        end
      end

      def release_lock
        if postgresql?
          release_pg_lock
        else
          release_file_lock
        end
      end

      def postgresql?
        ActiveRecord::Base.connection.adapter_name.downcase.include?('postgresql')
      end

      def acquire_pg_lock
        result = ActiveRecord::Base.connection.execute(
          "SELECT pg_try_advisory_lock(#{@config.repository_id.to_i})"
        )
        result.first['pg_try_advisory_lock'] == true ||
          result.first['pg_try_advisory_lock'] == 't'
      rescue StandardError => e
        Rails.logger.warn "[RedmineGitMirror] PG advisory lock failed, falling back to file lock: #{e.message}"
        acquire_file_lock
      end

      def release_pg_lock
        ActiveRecord::Base.connection.execute(
          "SELECT pg_advisory_unlock(#{@config.repository_id.to_i})"
        )
      rescue StandardError => e
        Rails.logger.warn "[RedmineGitMirror] PG advisory unlock failed: #{e.message}"
      end

      def lock_file_path
        dir = Rails.root.join('tmp', 'redmine_git_mirror', 'locks')
        FileUtils.mkdir_p(dir)
        File.join(dir, "#{@config.repository_id}.lock")
      end

      def acquire_file_lock
        @lock_file = File.open(lock_file_path, File::RDWR | File::CREAT, 0o600)
        @lock_file.flock(File::LOCK_EX | File::LOCK_NB)
      rescue Errno::EWOULDBLOCK
        @lock_file&.close
        @lock_file = nil
        false
      end

      def release_file_lock
        return unless @lock_file

        @lock_file.flock(File::LOCK_UN)
        @lock_file.close
        @lock_file = nil
      rescue StandardError
        nil
      end

      # -----------------------------------------------------------------------
      # Helpers
      # -----------------------------------------------------------------------

      def run_git(env, cmd)
        stdout, stderr, status = Open3.capture3(env, *cmd)
        [stdout, stderr, status.success?]
      end

      def count_all_commits(git_dir)
        out, _err, success = Open3.capture3(
          'git', '--git-dir', git_dir, 'rev-list', '--count', '--all'
        )
        success ? out.strip.to_i : 0
      rescue StandardError
        0
      end
    end
  end
end
