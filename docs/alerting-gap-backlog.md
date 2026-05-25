# Alerting Gap Backlog

This is a temporary execution ledger for alerting gaps that were identified
after the Prometheus and Alertmanager migration on `fanavm`.

The intent is simple:

- keep a repo-tracked list of useful missing alerts
- implement the items in this file step by step
- move completed work into the done section
- remove this file once the actionable backlog is exhausted

This document is not the architecture source of truth. That remains
[alerting-strategy.md](/Users/ihrachyshka/src/nix/docs/alerting-strategy.md).

## Ready To Implement

- Internal service blackbox probe alerts for `grafana`, `radarr`, `sonarr`,
  `lidarr`, `bazarr`, `prowlarr`, `transmission`, and `sabnzbd`.
- Beast RAID state alerts from `host_observability_md_*`.
- Beast HBA health alerts from `host_observability_hba_collect_success`,
  `host_observability_hba_healthy`, `host_observability_hba_degraded`, and
  `host_observability_hba_failed`.
- Fleet root filesystem usage alerts.
- Fleet host upgrade staleness alerts from
  `node_nixos_upgrade_last_success_time_seconds`.
- `srvarrvm` custom job freshness alerts for the transmission collector and the
  adaptive upload controller exporter.

## Needs Signal Work Or Verification

- Backup freshness and failure alerts for restic, Jellyfin backup, and Btrfs
  scrub.
- Generic failed systemd unit alerts once signal quality is verified fleetwide.
- `transmission-prioritizer`, `unifi-sync`, and upload-policy applier
  freshness/failure signals where no clean metrics exist yet.
- HBA per-drive media, predictive, and SMART-alert counters once their live
  Prometheus visibility is verified.
- Loki or log-derived alerts for repeated unit errors or error bursts.
- Network degradation alerts for sustained packet loss, retransmits, or drops
  once thresholds are validated against real baseline behavior.
- Media-pipeline policy alerts such as stuck SABnzbd queue or problematic
  Jellyfin transcode load once desired behavior is defined.

## Done

- Prometheus owns metric alert evaluation on `fanavm`.
- Alertmanager owns notification routing on `fanavm`.
- Existing POC alert families were migrated out of Grafana-managed rules into
  repo-managed Prometheus rules with `promtool` tests.
