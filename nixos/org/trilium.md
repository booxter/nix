# Trilium Notes on `org`

This deployment provides one Trilium instance at
`https://notes.ihar.dev`, exclusively for `ihar`.

Trilium is single-user software. The `trilium-users` Kanidm group therefore
contains only `ihar`, and the service has one Unix account, state directory,
SQLite database, and OIDC client. Do not add another person to the group: run
a separate instance or choose a multi-user notes service instead.

## Before the first deploy

No certificates, secrets, or DNS records are created by this code change.
Create a confidential OIDC secret on the Kanidm host, copy it into the Trilium
service secret, and generate a separate local break-glass password:

```sh
openssl rand -hex 32 \
  | nix run .#sops-set -- pki kanidm/oauth2/trilium/client_secret
nix run .#sops-copy -- \
  pki org kanidm/oauth2/trilium/client_secret \
  trilium/oidc/client_secret
openssl rand -hex 32 \
  | nix run .#sops-set -- org trilium/local_password
```

Issue the internal server certificate on `org` and the matching mTLS client
identity used by public ingress on `beast`:

```sh
nix run .#issue-internal-service-cert -- --host org --service notes
nix run .#issue-internal-service-cert -- --host beast --client notes
```

Create this public DNS record before deploying `beast`, so ACME validation can
succeed:

```text
notes.ihar.dev.  CNAME ihrachyshka-beast.freeddns.org.
```

Commit the encrypted `pki`, `org`, and `beast` secret changes, push the branch,
then deploy from that branch in dependency order:

```sh
nix run .#deploy -- --branch <branch> pki
nix run .#deploy -- --branch <branch> org
nix run .#deploy -- --branch <branch> beast
nix run .#deploy -- --branch <branch> fana
nix run .#deploy -- --branch <branch> srvarr
```

## Automatic bootstrap

`trilium-bootstrap.service` initializes a new database, installs the local
break-glass password from SOPS, and enables OIDC before the main service starts.
No first-run UI or MFA settings changes are required.

On the first OIDC sign-in, Trilium automatically binds the identity returned by
Kanidm. The OIDC client only issues tokens to `trilium-users`, whose sole member
is `ihar`, so no separate enrollment action is required and another identity
cannot claim the instance.

The local password remains in the encrypted `org` SOPS file for break-glass
recovery. To temporarily switch the login page back to that password:

```sh
ssh org "sudo sh -c '
  systemctl stop trilium
  sudo -u trilium sqlite3 /var/lib/trilium/document.db \
    \"UPDATE options SET value = '\''false'\'' WHERE name = '\''mfaEnabled'\'';
     UPDATE options SET value = '\''totp'\'' WHERE name = '\''mfaMethod'\'';\"
  systemctl start trilium
'"
```

The bootstrap unit re-enables OIDC on the next boot. To re-enable it without a
reboot, stop `trilium`, restart `trilium-bootstrap`, then start `trilium` again.

## Verification

```sh
ssh org 'systemctl --no-pager --full status trilium-bootstrap trilium'
ssh org 'curl -fsS http://127.0.0.1:18086/api/health-check'
curl -fsS https://notes.ihar.dev/api/health-check
```

Test a browser login and desktop or mobile sync against
`https://notes.ihar.dev`. An interactive OAuth proxy is intentionally not
placed in front of Trilium because it would intercept unattended sync
requests.

## Backups and alerts

Trilium keeps its own rotating local backups. In addition, at `04:30` the
repository's backup-artifact module uses SQLite's online backup API to stage a
consistent copy at:

```text
/var/lib/trilium-backup/latest/document.db
```

The raw live database and WAL files are excluded from restic. The remaining
state, including Trilium's local rotating backups, and the consistent artifact
are sent to the `org` restic repository on `beast` at about `04:45`, then
offloaded to B2 at about `06:00`.

Existing fleet rules cover:

- split-DNS, backend mTLS, and true WAN health probes;
- public DNS-chain failures for `notes.ihar.dev`;
- stale or failed SQLite artifact and restic jobs;
- `org` disk, memory, CPU, and host availability.

The UptimeRobot account is already at its ten-monitor limit, so Trilium relies
on the Prometheus WAN probe instead.

Force and inspect a backup after bootstrap:

```sh
ssh org \
  'sudo systemctl start restic-backups-beast.service && \
   sudo systemctl status restic-backups-beast.service --no-pager -n 100'
```

## Restore

Restore into a staging directory first, following `common/backup.md`. Restore
only the consistent artifact:

```sh
ssh org "sudo sh -c '
  export RESTIC_REPOSITORY=\"sftp:restic-org@beast:/volume2/backups/restic-prod/hosts/orgvm\"
  export RESTIC_PASSWORD_FILE=\"/run/secrets/backup/restic/local/password\"
  RESTORE_DIR=/var/tmp/trilium-restore-YYYYMMDD
  install -d -m 0700 \"\$RESTORE_DIR\"
  restic restore latest --target \"\$RESTORE_DIR\" \
    --include /var/lib/trilium-backup/latest
  sqlite3 \"\$RESTORE_DIR\"/var/lib/trilium-backup/latest/document.db \
    \"PRAGMA integrity_check;\"
'"
```

After the integrity check prints `ok`, stop Trilium and install the restored
database while preserving the previous file for rollback:

```sh
ssh org "sudo sh -c '
  restore_dir=/var/tmp/trilium-restore-YYYYMMDD
  src=\"\$restore_dir/var/lib/trilium-backup/latest/document.db\"
  systemctl stop trilium
  mv /var/lib/trilium/document.db \
    /var/lib/trilium/document.db.before-restore
  install -o trilium -g trilium -m 0640 \
    \"\$src\" \
    /var/lib/trilium/document.db
  systemctl start trilium
'"
```

## Rollback

For an application or configuration regression, deploy the prior known-good
branch to `beast`, `org`, `pki`, `fana`, and `srvarr` in that order. Removing
the NixOS service does not delete `/var/lib/trilium`, so its data remains
available for a corrected deployment. For a data regression, use the restore
procedure above instead of rolling back the whole VM.
