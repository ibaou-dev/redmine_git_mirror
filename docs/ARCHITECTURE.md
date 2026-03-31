# redmine_git_mirror — Architecture & Technical Decisions

## Problem Statement

Redmine's built-in Git repository integration requires:

1. The Git repository must already be cloned (bare) to a local filesystem path accessible by the Redmine process.
2. An **external** cron job (or another Docker container) must periodically execute `git fetch` on the local clone, then call `Repository.fetch_changesets` to import new commits into Redmine.
3. No built-in credential management beyond a single username/password pair.
4. No per-repository polling granularity — it's global or nothing.
5. No webhook support for push-based sync.

This creates an operational burden: teams must maintain out-of-band infrastructure just for basic Git repository visibility in Redmine.

## Solution

The `redmine_git_mirror` plugin eliminates this burden by managing the full lifecycle **inside Redmine**:

- Specify a remote Git URL (SSH or HTTPS) directly in the Redmine UI
- Store credentials securely (SSH keys on filesystem, tokens/passwords encrypted in DB)
- Automatically bare-clone the remote repository to a managed local path
- Schedule per-repository polling via cron expressions, managed by an in-process scheduler
- Expose a webhook endpoint for push-based sync (GitHub, GitLab, Bitbucket)
- Record a full audit log for every sync operation
- Provide an admin dashboard showing the health of all mirrors

---

## ADR-1: Model Architecture — Separate Config vs. STI Subclass

**Status**: Accepted

**Context**: The natural Redmine extension point for a new repository type is creating a new STI subclass of `Repository` (e.g., `Repository::GitMirror`) and registering it with `Redmine::Scm::Base.add`. However, this requires implementing a complete SCM adapter, registering a new SCM type in the admin UI, and would force users to create a *new* repository entry rather than enhancing an existing one.

**Decision**: Create a separate `GitMirrorConfig` model with a 1:1 foreign key to `repositories.id`. Patch `Repository::Git` via `include RepositoryGitPatch` to add `has_one :git_mirror_config`.

**Rationale**:
- The plugin is **additive** — it enhances existing Git repositories without replacing them
- Users retain the standard Redmine Git repository workflow; mirroring is optional
- No new SCM type registration needed — avoids touching `Setting.enabled_scm`
- `Repository::Git`'s adapter (`GitAdapter`) continues to serve file browsing via `--git-dir <local_path>`; the plugin only manages how that local path gets populated
- Cleaner rollback: deleting the `GitMirrorConfig` record destroys the mirror; the underlying `Repository::Git` record is unaffected

**Consequences**:
- The plugin must update `repository.url` (the local path) after the initial clone, so the Git adapter knows where to look
- A hook must inject the mirror status UI into the repository view page

---

## ADR-2: Credential Storage

**Status**: Accepted

**Context**: Three credential types are needed: SSH private keys, personal access tokens (PAT), and username/password pairs. All must be stored securely and never exposed in logs or UI.

**Decision**:
- **SSH private keys**: Written to `<rails_root>/tmp/redmine_git_mirror/ssh_keys/<uuid>` with mode `0600`. Only the UUID filename is stored in the database. Keys are managed via `CredentialManager` and injected into git via `GIT_SSH_COMMAND` env var.
- **Access tokens and passwords**: Encrypted using `Redmine::Ciphering` (AES-256-CBC, keyed from `database_cipher_key`). Stored in `*_enc` text columns. Exposed via plain-named getter/setter methods (`access_token`, `password`).
- **Webhook secrets**: Same `Redmine::Ciphering` approach in `webhook_secret_enc`.

**Rationale**:
- SSH keys in the database (even encrypted) create an export risk through DB backups, SQL injection, or misconfigured serialization. Filesystem storage with strict mode `0600` limits access to the web server process.
- `Redmine::Ciphering` is already vetted and tested by the Redmine project; reusing it avoids introducing a new encryption library.
- Separate `*_enc` column names make it clear to DB admins that these columns contain ciphertext.

**Consequences**:
- SSH keys must be re-uploaded if the `tmp/` directory is cleared (e.g., container restart without persistent volume)
- `tmp/redmine_git_mirror/ssh_keys/` must be included in backup/restore procedures if SSH auth is used
- Key files must be included in the `after_destroy` cleanup callback

---

## ADR-3: Background Processing — In-Process Scheduler

**Status**: Accepted

**Context**: Each `GitMirrorConfig` can have a different poll schedule. Options considered:
1. **Rufus-Scheduler** (in-process, thread-based)
2. **Rake task + external cron** (one cron entry for all repos)
3. **Active Job + Sidekiq** (persistent queue, separate process)
4. **Redmine's own cron via `config/initializers`** (none exists natively)

**Decision**: Use `rufus-scheduler` (`~> 3.9`) running in a background thread within the Redmine process.

**Rationale**:
- **No external dependencies**: Sidekiq requires Redis. A Rake task + cron defeats the purpose of per-repository scheduling.
- **Well-tested pattern**: Rufus-Scheduler is used by multiple production Redmine plugins.
- **Per-repo granularity**: Each `GitMirrorConfig` gets its own `cron` job, scheduled using its own expression.
- **Lifecycle management**: `after_save` and `after_destroy` callbacks on `GitMirrorConfig` call `Scheduler.schedule/unschedule` to keep jobs in sync with DB records.

**Consequences**:
- Scheduler is **not started in test environment** (`next if Rails.env.test?` guard in `after_initialize`).
- On **multi-worker Puma** deployments (N workers), N scheduler instances will fire — mitigated by the per-repo advisory lock (ADR-6).
- Memory overhead: one background thread per process, one `cron` job per enabled config.

---

## ADR-4: Webhook Verification

**Status**: Accepted

**Context**: Three major Git hosts use different webhook verification mechanisms:
- **GitHub / Bitbucket**: HMAC-SHA256 over raw request body, provided in `X-Hub-Signature-256` header
- **GitLab**: Simple token comparison via `X-Gitlab-Token` header

Additionally, webhooks can be replayed by attackers to trigger unnecessary syncs (or DoS).

**Decision**: `WebhookVerifier` service detects the platform from event headers, then applies the appropriate verification. Replay attack prevention uses the `git_mirror_webhook_deliveries` table (indexed by UUID, TTL 15 minutes). Rate limiting uses `Rails.cache` (60 req/min per repo+IP).

**Rationale**:
- HMAC-SHA256 with `ActiveSupport::SecurityUtils.secure_compare` prevents timing attacks.
- UUID-based replay prevention is stateless with respect to the Git host — no coordination needed.
- `Rails.cache` for rate limiting is available without any additional infrastructure (memory store or Redis).

**Consequences**:
- `git_mirror_webhook_deliveries` must be periodically cleaned up (hourly Rufus job).
- If `Rails.cache` is memory-store (default), rate limit counters reset on process restart — acceptable for abuse prevention, not for strict metering.

---

## ADR-5: Local Path Management

**Status**: Accepted

**Context**: The local bare-clone path must be deterministic, unique per repository, and safe against path traversal attacks.

**Decision**: Path computed as `<base_dir>/<sanitized_project_identifier>/<sanitized_repo_identifier>.git`. Both identifier components are sanitized with `gsub(/[^a-z0-9\-_.]/, '_').downcase`. A `validate :validate_safe_local_path` assertion checks that the computed path starts with `base_dir` before any filesystem operation. Cleanup in `after_destroy` also checks this prefix before calling `FileUtils.rm_rf`.

**Default base_dir**: `<rails_root>/repositories/redmine_git_mirror/`
**Override**: Admin plugin settings → `git_mirror_base_dir`

**Rationale**:
- Deterministic paths allow recovery: if a `GitMirrorConfig` record is deleted and recreated, the same path is reused (and the existing clone is detected and fetched rather than re-cloned).
- The prefix guard before `rm_rf` is a belt-and-suspenders defense against misconfigured `base_dir` values.

---

## ADR-6: Concurrency — Preventing Double-Sync

**Status**: Accepted

**Context**: On Puma with multiple workers, each worker has its own Rufus-Scheduler instance. Multiple workers can fire the same cron job simultaneously. Additionally, a manual sync trigger could overlap with a scheduled sync.

**Decision**: Per-repository DB advisory lock. For PostgreSQL: `pg_try_advisory_lock(<repository_id>)`. For MySQL/MariaDB: file lock at `tmp/redmine_git_mirror/locks/<repo_id>.lock` using `File::LOCK_EX | File::LOCK_NB`.

A secondary `syncing` boolean flag in `git_mirror_configs` provides UI visibility (showing "Running" in the status badge) and a stale-lock recovery mechanism: if `syncing = true && sync_started_at < 1.hour.ago`, the next sync attempt resets the flag before proceeding.

**Rationale**:
- DB advisory locks are non-blocking (`pg_try_advisory_lock` returns immediately), do not require a transactions, and are automatically released if the process dies.
- File locks provide equivalent semantics on non-PostgreSQL deployments.
- The `syncing` flag provides observability without being the source of truth for locking.

---

## ADR-7: Testing Strategy

**Status**: Accepted

**Context**: The plugin interacts with the filesystem (SSH keys, bare repos), the git CLI (via `Open3`), the database, and the HTTP layer (webhook controller).

**Decision**:
- **Unit tests for services** (CredentialManager, DiskGuard, WebhookVerifier, MirrorSyncService): stub `Open3.capture3` and `File` operations where possible; use real temp directories for filesystem tests.
- **Unit tests for models** (GitMirrorConfig, etc.): use `ActiveRecord` without hitting the DB where possible via `.new`; hit the DB for association/validation tests.
- **Integration tests** for the webhook controller: use `ActionDispatch::IntegrationTest` with crafted request headers and bodies.
- **No live git network calls**: all tests that exercise git operations use local bare repos created in `test/tmp/`.
- **Rufus-Scheduler not started in tests**: guarded by `next if Rails.env.test?`.

---

## Data Flow Diagrams

### Initial Setup

```
User fills form (remote_url, auth_type, creds, poll_cron)
    │
    ▼
GitMirrorConfigsController#create
    │   Validates and saves GitMirrorConfig
    │   Stores encrypted credentials
    │   Generates webhook_token
    │   Computes local_path
    │
    ▼ after_save callback
Scheduler.schedule(config)          ← registers cron job
    │
    ▼ background Thread (initial sync)
MirrorSyncService#call
    ├── DiskGuard.check!
    ├── acquire_lock
    ├── GitMirrorSyncLog.create! (status: running)
    ├── CredentialManager.git_env
    ├── git clone --bare --mirror <remote_url> <local_path>
    ├── repository.update_columns(url: local_path)
    ├── repository.fetch_changesets       ← Redmine imports commits
    └── GitMirrorSyncLog.complete! (status: success)
```

### Scheduled Polling

```
Rufus::Scheduler fires cron job for config N
    │
    ▼
Scheduler#safe_sync(config_id, 'scheduler')
    │   Reloads config from DB (picks up credential changes)
    │
    ▼
MirrorSyncService#call
    ├── acquire_lock (skip if held)
    ├── git --git-dir <local_path> fetch --all --prune --tags
    ├── repository.fetch_changesets
    └── GitMirrorSyncLog.complete!
```

### Webhook Push

```
POST /git_mirror/webhook/:token
    │
    ▼
GitMirrorWebhookController#receive
    ├── find_config_by_token
    ├── check_webhook_enabled
    ├── rate_limit! (60/min per repo+IP)
    ├── WebhookVerifier#verify!
    │   ├── check_replay_attack!
    │   ├── detect_platform
    │   └── verify_github! / verify_gitlab! / verify_bitbucket!
    ├── GitMirrorWebhookDelivery.record!
    ├── Thread.new { MirrorSyncService.new(config, trigger_type: 'webhook').call }
    └── render json: { status: 'queued' }, status: 200
```

---

## Security Checklist

| Concern | Mitigation |
|---|---|
| SSH key exposure | Keys on filesystem, mode 0600, never in DB |
| Token/password exposure | AES-256-CBC via Redmine::Ciphering, `*_enc` columns |
| Webhook spoofing | HMAC-SHA256 (GitHub/Bitbucket), token compare (GitLab) |
| Webhook replay | UUID deduplication table with 10-min TTL |
| Webhook DoS | 60 req/min rate limit per repo+IP via Rails.cache |
| Path traversal (local_path) | Regex sanitize + prefix guard before mkdir/rm_rf |
| Shell injection (git args) | All git calls use `Open3.capture3(*array)` — no shell expansion |
| SSH injection | SSH key filenames validated as UUID regex before use |
| Double sync | DB advisory lock + `syncing` flag with stale recovery |
| Orphan cleanup | after_destroy removes SSH key file and local mirror |

---

## Limitations and Future Work

- **No automatic re-clone on corruption**: If the local bare repo becomes corrupted, the operator must delete `local_path` manually; the next sync will detect the missing directory and clone fresh.
- **Single remote per repository**: The plugin supports one remote URL per Redmine repository. Multiple remotes would require schema changes.
- **No SSH host key management**: `StrictHostKeyChecking=no` is used for simplicity. A future enhancement should allow uploading known_hosts entries.
- **Rufus-Scheduler on multi-worker**: The advisory lock mitigates double-sync but every worker carries a scheduler thread. A future enhancement could use a shared job queue (Solid Queue or a lightweight Redis-backed option).
- **No branch filter**: All branches and tags are fetched. A future enhancement could support `refspec` configuration.
