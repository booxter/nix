# Telegram Archive

`org` runs [GeiserX/Telegram-Archive](https://github.com/GeiserX/Telegram-Archive)
for the configured Telegram chats. The viewer is available at
`https://tg.home.arpa` behind the fleet's Kanidm-backed `oauth2-proxy` gate;
membership in `infra-admins` is required. The viewer trusts only the `X-User`
identity header injected by the loopback reverse proxy, and `ihar` receives
viewer administrator access.

The scheduler maintains both a four-hour incremental sync and Telegram's
real-time event listener. New messages, edits, chat actions, media up to 100
MiB, and deletion events are captured. Deleted messages remain in the archive
and are marked as deleted (`DELETION_MODE=soft`). The initial import can only
retrieve history still available through Telegram: a chat with a 24-hour
auto-delete policy cannot be backfilled past messages Telegram has already
removed. Keeping the listener healthy is therefore important.

## Secrets

The following keys live in `secrets/main/org.yaml`:

- `telegramArchive/apiId`: numeric API ID from `my.telegram.org/apps`
- `telegramArchive/apiHash`: API hash paired with that ID
- `telegramArchive/phone`: account phone number in international form
- `telegramArchive/chatIds`: a JSON array serialized as one YAML string, for
  example `'[-1001234567890, -1009876543210]'`
- `oauth2-proxy/tg/client_secret`: copy of the Kanidm `tg` client secret
- `oauth2-proxy/tg/cookie_secret`: independent random cookie-encryption secret

The chat-ID value is deliberately a serialized JSON array because `sops-nix`
secret paths expose scalar leaves as files. The service validates it as a
non-empty array of integer IDs and converts it to the comma-separated format
expected by Telegram Archive. Add another ID to the array to expand coverage.

Kanidm's authoritative OIDC copy is
`kanidm/oauth2/tg/client_secret` in `secrets/main/pki.yaml`. Use the same value
on both hosts; `nix run .#sops-copy` is the intended transfer mechanism.

## First authentication

The scheduler has a systemd condition on its Telethon session, so it remains
stopped after a fresh deployment. Authenticate interactively on `org`:

```bash
ssh -t org 'sudo telegram-archive-auth'
ssh org 'sudo systemctl start telegram-archive-scheduler.service'
```

Telegram may request the login code sent to the account and its two-factor
password. The resulting session is stored at
`/var/lib/telegram-archive/session/telegram_archive.session`; access to that
file is equivalent to access to the Telegram account and must remain secret.

## Operations and recovery

The archive database and authenticated Telethon session are staged with
SQLite-consistent backups and included in `org`'s existing restic backup to
`beast` and B2. The raw live SQLite files are excluded from restic. Backup
artifact services are conditionally skipped before the first database/session
exists.

Useful checks:

```bash
ssh org 'systemctl status telegram-archive-scheduler telegram-archive-viewer oauth2-proxy-tg'
ssh org 'journalctl -u telegram-archive-scheduler -f'
ssh org 'curl -fsS http://127.0.0.1:8091/api/health'
```

If the session is invalidated, stop the scheduler, rerun
`sudo telegram-archive-auth`, and start the scheduler again. A restored session
may still require reauthentication if Telegram has revoked it.
