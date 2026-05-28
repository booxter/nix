# Backup and Restore

This repo supports a two-tier restic backup model:

- local backup to `beast` over SSH/SFTP
- cloud offload from `beast` to Backblaze B2 through `rclone`

Each host should have:

- its own local repository on `beast`
- its own cloud repository path
- its own local restic password
- its own cloud restic password
- its own SSH keypair for the local backup target
- its cloud offload configured on `beast`

`srvarr` is the first concrete example of this pattern.

## Repository Layout

### Local on Beast

Per-host local repositories live under:

```text
/volume2/backups/restic-prod/hosts/<host>
```

Example for `srvarr`:

```text
/volume2/backups/restic-prod/hosts/srvarr
```

The corresponding restic repository URL is:

```text
sftp:restic-<host>@beast:/volume2/backups/restic-prod/hosts/<host>
```

Example:

```text
sftp:restic-srvarr@beast:/volume2/backups/restic-prod/hosts/srvarr
```

### Cloud on B2

Per-host cloud repositories live under:

```text
hosts/<host>
```

inside the shared bucket:

```text
ihar-restic-prod
```

The corresponding restic repository URL is:

```text
rclone:b2:ihar-restic-prod/hosts/<host>
```

Example:

```text
rclone:b2:ihar-restic-prod/hosts/srvarr
```

## Secrets Model

Each source host keeps:

- `backup.restic.local.password`
- `backup.restic.local.ssh.privateKey`

`beast` keeps:

- the corresponding public key in config for each backup client
- the local repository password for each client's offload job
- the cloud repository password for each client's offload job
- the shared Backblaze B2 credentials for cloud offload

## Scheduling

Backups should be scheduled outside the NixOS auto-upgrade reboot window and,
for hosts that run daily auto-upgrades, before that host's daily upgrade starts.

In the current setup:

- auto-upgrades are scheduled at `05:15` with up to `5m` random delay
- local application-consistent prep jobs run around `04:30`
- local host-to-`beast` backups run around `04:45` with up to `5m` random delay
- cloud offload from `beast` runs around `06:00` with up to `5m` random delay

### Backup Timeline

The intended order is:

1. Application-specific prep jobs create consistent backup artifacts locally.
2. Hosts push their local restic backups to `beast`.
3. Daily auto-upgrades start for those hosts.
4. Hosts reboot and settle back into service if the upgrade needs a reboot.
5. `beast` offloads local repositories to cloud storage.

This sequencing is intentional:

- It captures application state before the daily upgrade can restart services
  or reboot the host.
- It gives application-specific prep jobs a chance to produce cleaner backup
  inputs before restic runs.
- It keeps cloud offload behind the local `host -> beast` step so `beast`
  copies the newest local snapshots instead of racing with them.
- It reduces lock contention on shared local repositories between client
  backups and `beast`-side cloud offload jobs.

When adding a new host or a new application-specific backup job, keep it in
this same order: local prep first, local restic backup second, daily upgrade
third, cloud offload last.

This separation is documented both in the backup modules and in the
auto-upgrade schedule definitions.

## Trigger Backups

### Generic Pattern

Run the local backup for a host:

```sh
ssh <host>.local \
  'sudo systemctl start restic-backups-beast.service && \
   sudo systemctl status restic-backups-beast.service --no-pager -n 80'
```

Run the cloud offload for a host on `beast`:

```sh
ssh beast.local \
  'sudo systemctl start restic-<host>-cloud-offload.service && \
   sudo systemctl status restic-<host>-cloud-offload.service --no-pager -n 80'
```

Watch logs:

```sh
ssh <host>.local 'sudo journalctl -fu restic-backups-beast.service'
ssh beast.local 'sudo journalctl -fu restic-<host>-cloud-offload.service'
```

List timers:

```sh
ssh beast.local 'systemctl list-timers --all | rg restic-.*cloud-offload'
```

### Example: `srvarr`

```sh
ssh srvarr.local \
  'sudo systemctl start restic-backups-beast.service && \
   sudo systemctl status restic-backups-beast.service --no-pager -n 80'
ssh beast.local \
  'sudo systemctl start restic-srvarr-cloud-offload.service && \
   sudo systemctl status restic-srvarr-cloud-offload.service --no-pager -n 80'
```

## Inspect Snapshots

### Local Repository

Generic pattern:

```sh
ssh <host>.local "sudo sh -c '
  export RESTIC_REPOSITORY=\"sftp:restic-<host>@beast:/volume2/backups/restic-prod/hosts/<host>\"
  export RESTIC_PASSWORD_FILE=\"/run/secrets/backup/restic/local/password\"
  restic snapshots
'"
```

Example for `srvarr`:

```sh
ssh srvarr.local "sudo sh -c '
  export RESTIC_REPOSITORY=\"sftp:restic-srvarr@beast:/volume2/backups/restic-prod/hosts/srvarr\"
  export RESTIC_PASSWORD_FILE=\"/run/secrets/backup/restic/local/password\"
  restic snapshots
'"
```

### Cloud Repository

Generic pattern from `beast`:

```sh
ssh beast.local "sudo sh -c '
  export RESTIC_REPOSITORY=\"rclone:b2:ihar-restic-prod/hosts/<host>\"
  export RESTIC_PASSWORD_FILE=\"/run/secrets/backup/restic/<host>/cloud/password\"
  export RCLONE_CONFIG=\"/run/secrets/rendered/restic-<host>-cloud-rclone.conf\"
  restic snapshots
'"
```

Example for `srvarr`:

```sh
ssh beast.local "sudo sh -c '
  export RESTIC_REPOSITORY=\"rclone:b2:ihar-restic-prod/hosts/srvarr\"
  export RESTIC_PASSWORD_FILE=\"/run/secrets/backup/restic/srvarr/cloud/password\"
  export RCLONE_CONFIG=\"/run/secrets/rendered/restic-srvarr-cloud-rclone.conf\"
  restic snapshots
'"
```

## Restore Procedure

Restore into a staging directory first. Do not restore directly into `/` until
the snapshot contents are verified.

### Generic Restore Pattern

Local restore:

```sh
ssh <host>.local "sudo sh -c '
  export RESTIC_REPOSITORY=\"sftp:restic-<host>@beast:/volume2/backups/restic-prod/hosts/<host>\"
  export RESTIC_PASSWORD_FILE=\"/run/secrets/backup/restic/local/password\"
  restic restore latest --target /restore-test
'"
```

Cloud restore from `beast`:

```sh
ssh beast.local "sudo sh -c '
  export RESTIC_REPOSITORY=\"rclone:b2:ihar-restic-prod/hosts/<host>\"
  export RESTIC_PASSWORD_FILE=\"/run/secrets/backup/restic/<host>/cloud/password\"
  export RCLONE_CONFIG=\"/run/secrets/rendered/restic-<host>-cloud-rclone.conf\"
  restic restore latest --target /restore-test
'"
```

### Restore Example: `srvarr`

Local:

```sh
ssh srvarr.local "sudo sh -c '
  export RESTIC_REPOSITORY=\"sftp:restic-srvarr@beast:/volume2/backups/restic-prod/hosts/srvarr\"
  export RESTIC_PASSWORD_FILE=\"/run/secrets/backup/restic/local/password\"
  restic restore latest --target /restore-test
'"
```

Cloud:

```sh
ssh beast.local "sudo sh -c '
  export RESTIC_REPOSITORY=\"rclone:b2:ihar-restic-prod/hosts/srvarr\"
  export RESTIC_PASSWORD_FILE=\"/run/secrets/backup/restic/srvarr/cloud/password\"
  export RCLONE_CONFIG=\"/run/secrets/rendered/restic-srvarr-cloud-rclone.conf\"
  restic restore latest --target /restore-test
'"
```

For `srvarr`, restored files appear under the same legacy state root beneath
`/restore-test`.

## Restore a Single Subtree

Example generic pattern:

```sh
ssh <host>.local "sudo sh -c '
  export RESTIC_REPOSITORY=\"sftp:restic-<host>@beast:/volume2/backups/restic-prod/hosts/<host>\"
  export RESTIC_PASSWORD_FILE=\"/run/secrets/backup/restic/local/password\"
  restic restore latest --target /restore-test --include \"/path/to/subtree\"
'"
```

Example for `srvarr` restoring Radarr state:

```sh
ssh srvarr.local "sudo sh -c '
  STATE_ROOT=/data/.state/nixarr
  export RESTIC_REPOSITORY=\"sftp:restic-srvarr@beast:/volume2/backups/restic-prod/hosts/srvarr\"
  export RESTIC_PASSWORD_FILE=\"/run/secrets/backup/restic/local/password\"
  restic restore latest --target /restore-test --include \"$STATE_ROOT/radarr\"
'"
```

## Live Recovery Pattern

For a real restore:

1. Stop affected services.
2. Restore into `/restore-test`.
3. Inspect the restored files.
4. Copy the required directories back into place.
5. Start services again.

Example stop/start sequence for `srvarr`:

```sh
ssh srvarr.local 'sudo sh -c "
  STATE_ROOT=/data/.state/nixarr
  systemctl stop radarr sonarr lidarr readarr readarr-audiobook \
    bazarr prowlarr sabnzbd transmission seerr audiobookshelf
  rsync -a \"/restore-test\$STATE_ROOT/\" \"\$STATE_ROOT/\"
  systemctl start radarr sonarr lidarr readarr readarr-audiobook \
    bazarr prowlarr sabnzbd transmission seerr audiobookshelf
"'
```

## Adoption Pattern for New Hosts

To add another host later:

1. Add a local backup module for that host, modeled after `srvarr`.
2. Choose the host-specific source paths to back up.
3. Generate a dedicated SSH keypair for `host -> beast`.
4. Add the host public key to `backupClients` in `beast`'s backup target config.
5. Add host-local secrets for:
   - local restic password
   - local SSH private key
   - cloud restic password
   - B2 application key id
   - B2 application key
6. Point local backup to:
   - `sftp:restic-<host>@beast:/volume2/backups/restic-prod/hosts/<host>`
7. Point cloud backup to:
   - `rclone:b2:ihar-restic-prod/hosts/<host>`

## Notes

- The first backup run is full. Later runs are incremental.
- Cloud offload runs from `beast` and is traffic-shaped there to `4mbit`.
- `Ctrl-C` during `systemctl start ...` only detaches the terminal from
  waiting on the service; it does not stop the backup job.
- The restic repository password is required to read or restore backups.
