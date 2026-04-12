# redmine_git_mirror

Enhances Redmine's built-in Git repository integration with automatic remote mirroring, secure credential storage, configurable polling, and webhook support.

## Features

- Automatic remote repository mirroring (clone + fetch)
- Secure credential storage: SSH keys, access tokens, username/password
- Per-repository configurable polling schedules (cron format)
- Webhook support for push-based sync (GitHub, GitLab, Bitbucket)
- Full sync audit log viewable per-repository
- Admin dashboard at Administration > Git Mirror

## Requirements

- Redmine 5.0 or higher
- Ruby gem: `rufus-scheduler ~> 3.9` (installed automatically via `PluginGemfile`)

## Installation

```bash
cd /path/to/redmine
git clone https://github.com/ibaou-dev/redmine_git_mirror.git plugins/redmine_git_mirror
bundle install
bundle exec rake redmine:plugins:migrate NAME=redmine_git_mirror RAILS_ENV=production
# restart Redmine
touch tmp/restart.txt
```

## Configuration

1. Go to **Administration > Plugins > Redmine Git Mirror > Configure**
2. Optionally set the mirror base directory (defaults to `<redmine_root>/repositories/redmine_git_mirror`)
3. Enable the **Git Mirror** module in a project's **Settings > Modules**
4. In **Project Settings > Git Mirror**, click **Add Mirror**
5. Enter the remote URL and authentication details — a Redmine Git repository record is created automatically
6. The initial sync runs in the background; the repository browser becomes available once the first sync completes

> If you already have an existing Redmine Git repository and want to add mirroring to it, use the **Configure Mirror** link on the repository's browse page.

## Webhook Setup

After creating a mirror configuration, copy the displayed Webhook URL and add it as a push webhook in your Git host (GitHub / GitLab / Bitbucket). Optionally set a webhook secret for HMAC-SHA256 signature verification.

## Security

- SSH private keys are stored on the filesystem with mode `0600`, never in the database
- Access tokens and passwords are encrypted with Redmine's built-in AES-256-CBC cipher
- Webhook secrets are encrypted in the database
- HMAC-SHA256 verification prevents unauthorized sync triggers
- Rate limiting (60 requests/minute per repo/IP) on the webhook endpoint

## License

GPL-2.0 — see [LICENSE](LICENSE)
