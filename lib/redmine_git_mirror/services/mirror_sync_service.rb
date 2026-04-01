require 'open3'
require 'fileutils'

module RedmineGitMirror
  module Services
    # Performs a git clone or fetch for a given GitMirrorConfig.
    #
    # Responsibilities:
    #   - Acquire a per-repository file lock (prevents double-sync)
    #   - Check disk space before operating
    #   - Clone bare repo on first run, fetch --all --prune on subsequent runs
    #   - Retry transient failures (3 attempts, exponential backoff)
    #   - Record a GitMirrorSyncLog entry for each run
    #   - Call repository.fetch_changesets to import commits into Redmine
    #   - Update GitMirrorConfig sync state columns
    #
    # Connection management:
    #   DB connections are held only during brief setup/teardown phases.
    #   Git I/O runs without holding any pool connection so long-running or
    #   hung operations cannot starve the connection pool.
    class MirrorSyncService
      RETRY_DELAYS   = [5, 30, 120].freeze   # seconds between retry attempts
      OUTPUT_MAX     = 10 * 1024             # cap git output stored in DB at 10 KB
      LOCK_TIMEOUT   = 1.hour               # after this, a sync is considered stale
      CLONE_TIMEOUT  = 600                  # max seconds for git clone
      FETCH_TIMEOUT  = 300                  # max seconds for git fetch/remote set-url

      SyncResult = Struct.new(:status, :commits_fetched, :output, :error_message, keyword_init: true)

      def initialize(config, trigger_type:)
        @config       = config
        @trigger_type = trigger_type
        @credential   = CredentialManager.new(config)
        @lock_file    = nil
        @log          = nil
      end

      # Entry point. Returns a SyncResult.
      def call
        # ── Phase 1: DB setup (brief connection hold) ──────────────────────────
        with_db do
          @config.reset_stale_sync! if @config.stale_sync?

          unless acquire_lock
            Rails.logger.info "[RedmineGitMirror] Skipping sync for config #{@config.id} — lock held"
            return SyncResult.new(status: :skipped, commits_fetched: 0, output: nil, error_message: nil)
          end

          @log = GitMirrorSyncLog.create!(
            git_mirror_config_id: @config.id,
            trigger_type:         @trigger_type.to_s,
            started_at:           Time.current,
            status:               'running'
          )
          @config.update_columns(syncing: true, sync_started_at: Time.current)
        end

        # ── Phase 2: Git operations — NO DB connection held ────────────────────
        result = perform_git_with_retry

        # ── Phase 3: DB teardown (brief connection hold) ───────────────────────
        with_db do
          import_changesets(result)
          update_config_after_sync(result)
          @log.complete!(
            status:          result.status == :success ? 'success' : 'failed',
            commits_fetched: result.commits_fetched,
            output:          result.output,
            error_message:   result.error_message
          )
        end

        result
      rescue StandardError => e
        Rails.logger.error "[RedmineGitMirror] Unexpected error during sync: #{e.full_message}"
        SyncResult.new(status: :error, commits_fetched: 0, output: nil, error_message: e.message)
      ensure
        release_lock
        with_db { @config.update_columns(syncing: false) }
      end

      # -----------------------------------------------------------------------
      private
      # -----------------------------------------------------------------------

      def with_db(&block)
        ActiveRecord::Base.connection_pool.with_connection(&block)
      end

      def perform_git_with_retry
        last_error   = nil
        total_output = ''

        RETRY_DELAYS.each_with_index do |delay, attempt|
          begin
            return perform_git_operation
          rescue StandardError => e
            last_error    = e
            total_output += "\n[Attempt #{attempt + 1} failed: #{e.message}]"
            Rails.logger.warn "[RedmineGitMirror] Sync attempt #{attempt + 1} failed: #{e.message}"
            sleep(delay) unless attempt == RETRY_DELAYS.length - 1
          end
        end

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

        output, error, success = run_git(env, cmd, timeout: CLONE_TIMEOUT)

        raise "git clone failed:\n#{error}" unless success

        # Update the repository record's url to point to the new local mirror
        with_db { @config.repository.update_columns(url: local_path) }

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
        run_git(env, ['git', '--git-dir', local_path, 'remote', 'set-url', 'origin', remote_url],
                timeout: FETCH_TIMEOUT)

        cmd = ['git', '--git-dir', local_path, 'fetch', '--all', '--prune', '--tags']
        output, error, success = run_git(env, cmd, timeout: FETCH_TIMEOUT)

        raise "git fetch failed:\n#{error}" unless success

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
      # Locking — file-based only (no DB connection required)
      # -----------------------------------------------------------------------

      def acquire_lock
        acquire_file_lock
      end

      def release_lock
        release_file_lock
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

      # Run a git command with a hard timeout. Kills the process group on timeout.
      def run_git(env, cmd, timeout:)
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe

        pid = Process.spawn(env, *cmd, out: stdout_w, err: stderr_w, pgroup: true)
        stdout_w.close
        stderr_w.close

        wait_thr = Thread.new { Process.wait2(pid) }

        if wait_thr.join(timeout)
          _, status = wait_thr.value
          [stdout_r.read, stderr_r.read, status.success?]
        else
          # Timed out — kill the entire process group
          begin
            Process.kill('-TERM', pid)
            sleep 2
            Process.kill('-KILL', pid)
          rescue Errno::ESRCH
            # Process already gone
          end
          wait_thr.join(5)
          raise "Git command timed out after #{timeout}s: #{cmd.first(3).join(' ')}"
        end
      ensure
        [stdout_r, stdout_w, stderr_r, stderr_w].each { |io| io.close rescue nil }
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
