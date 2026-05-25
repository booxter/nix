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

## Done

- Prometheus owns metric alert evaluation on `fanavm`.
- Alertmanager owns notification routing on `fanavm`.
- Existing POC alert families were migrated out of Grafana-managed rules into
  repo-managed Prometheus rules with `promtool` tests.
- Internal blackbox service probes now alert for `grafana`, `radarr`,
  `sonarr`, `lidarr`, `bazarr`, `prowlarr`, `transmission`, and `sabnzbd`.
- Beast RAID degraded state now alerts from `host_observability_md_degraded`.
- Beast HBA controller degraded and failed states now alert from
  `host_observability_hba_degraded` and `host_observability_hba_failed`.
- Fleet root filesystem usage now alerts at warning and critical thresholds.
- Fleet host upgrade staleness now alerts from
  `node_nixos_upgrade_last_success_time_seconds`.
- `srvarrvm` Transmission collector and adaptive upload controller freshness and
  failure states now alert from their existing metrics.
