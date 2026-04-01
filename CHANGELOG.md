# Changelog

All notable changes to `redmine_git_mirror` are documented here.

## [Unreleased] — post-initial e2e stabilisation

### Added

- **Auto-create `Repository::Git`** when adding a mirror — no pre-existing repository
  required. The controller derives a URL-safe identifier from the remote URL and creates
  the repository automatically inside a transaction. Backward compatible: passing
  `repository_id` in the form still links to an existing repository.
- **Remote URL change handling** in the edit flow: if the remote URL is changed on an
  existing config that has a local clone, the clone is deleted and sync status is reset
  to Pending. This prevents `git fetch` from merging unrelated histories into the existing
  bare repo. A warning is displayed in the edit form.
- **Settings tab partial** (`_settings_tab.html.erb`) — was missing at initial commit,
  causing a 404 on Project Settings → Git Mirror. Lists all mirrors for the project with
  status badges and action links; includes a top-level "Add Mirror" button.
- **`confirm_destroy` route and action** — was missing, causing a 403. Added GET member
  route, controller action, and the action to the `manage_git_mirror` permission list.
- **`hint_remote_url_change` i18n key** in `config/locales/en.yml`.
- **`CHANGELOG.md`** (this file).

### Fixed

- **Connection pool exhaustion**: `MirrorSyncService` now releases its DB connection
  before git I/O and re-acquires it only for brief setup/teardown phases. Previously,
  a single `with_connection` block wrapped the entire sync including potentially
  long-running `git clone` / `git fetch` calls, causing pool starvation under concurrent
  operations.
- **Git command timeout**: `run_git` replaced `Open3.capture3` (blocking, no timeout)
  with `Process.spawn` + `Thread#join(timeout)` + `Process.kill('-KILL', pgid)`.
  Limits: 600 s for clone, 300 s for fetch. Prevents hung git operations from holding
  DB connections indefinitely.
- **PG advisory locks removed**: `pg_try_advisory_lock` is connection-scoped and
  incompatible with releasing the connection mid-sync. Replaced with file locks
  (`File::LOCK_EX | File::LOCK_NB`) which are connection-independent.
- **All background thread callers** (`queue_initial_sync`, `trigger_sync`, webhook
  `receive`, `Scheduler#safe_sync`) now wrap only the initial config load in
  `with_connection`, not the entire sync call.
- **SSH key CRLF normalization**: keys pasted via a browser textarea on Windows have
  `\r\n` line endings. OpenSSH's libcrypto rejects keys containing `\r`. The
  `CredentialManager#write_ssh_key` method now strips `\r` and ensures a trailing `\n`
  before writing to disk.
- **`Rufus::Scheduler::NotFound`** constant reference in `GitMirrorConfig#validate_cron_expression`
  removed — this constant does not exist in rufus-scheduler 3.9 and would raise
  `NameError` when an invalid cron expression was submitted.
- **Admin dashboard repository links** used wrong Redmine route params (`project_id:`
  and `id:`) — Redmine's repository routes use `:id` for the project and
  `:repository_id` for the repository. Fixed in `git_mirror_admin/index.html.erb`.
- **Settings tab cancel/redirect buttons** throughout the configs controller and views
  now consistently target `tab: 'git_mirror'` instead of `tab: 'repositories'`.
- **`pagination_links_full`** in `git_mirror_sync_logs/index.html.erb` now receives a
  `Redmine::Pagination::Paginator` object as required by Redmine's helper.
- **`error_messages_for`** in `_form.html.erb` now called with the object directly
  (`error_messages_for @config`) rather than the Rails 2 symbol syntax.
- **Route helpers** in views and hooks no longer pass `@repository` as an extra
  positional argument (it was being appended as a format suffix, generating URLs like
  `trigger_sync.2`).
- **Scheduler cleanup job** now wraps `GitMirrorWebhookDelivery.cleanup_old!` in
  `with_connection` (it runs in a Rufus background thread, not a request thread).
