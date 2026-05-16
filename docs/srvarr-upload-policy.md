# `srvarr` Upload Policy

This document describes the current upload-control model on `srvarr`.

## Overview

There are two active control layers:

- adaptive global upload budgeting from Jellyfin playback
- native private-tracker prioritization inside the patched Transmission daemon

There is no public/private sub-cap split.

`transmission-tracker-prioritizer` still exists in-tree, but on `srvarr` it is
currently **disabled**. If re-enabled, it only:

- marks preferred torrents `bandwidthPriority = high`
- marks other torrents `bandwidthPriority = normal`
- demotes non-preferred completed torrents to `bandwidthPriority = low` once
  `uploadRatio >= 3.0`
- exports per-class metrics for Prometheus / Grafana

It does not manage bandwidth groups, public caps, or SABnzbd suppression.

## Active Pieces

Host wiring:

- [nixos/srvarrvm/adaptive-upload-policy.nix](../nixos/srvarrvm/adaptive-upload-policy.nix)
- [nixos/srvarrvm/default.nix](../nixos/srvarrvm/default.nix)
- [overlays/default.nix](../overlays/default.nix)

Optional helper module:

- [nixos/srvarrvm/transmission-tracker-prioritizer.nix](../nixos/srvarrvm/transmission-tracker-prioritizer.nix)

Important current facts:

- `srvarr` imports `adaptive-upload-policy.nix`
- `srvarr` does **not** currently import `transmission-tracker-prioritizer.nix`
- Transmission gets:
  - `TR_TRACKER_PRIORITY_FILE=/run/secrets/transmissionTrackerHosts`
- the preferred tracker host secret lives at:
  - `/run/secrets/transmissionTrackerHosts`

## Current Behavior

### 1. Adaptive Global Cap

`jellyfin-upload-policy` reads Jellyfin exporter metrics from `beast` and
computes a host-wide upload target.

Current values:

- idle ceiling: `25mbit`
- minimum target with healthy exporter data: `0.5mbit`
- conservative fallback when exporter data is unavailable: `8mbit`
- bitrate headroom: `10%`
- relaxation hold: `90s`

Transmission then gets a session upload cap equal to `95%` of that target.

Examples:

- `25mbit` target -> `2968 kB/s`
- `15mbit` target -> `1781 kB/s`
- `8mbit` fallback -> `950 kB/s`
- `0.5mbit` minimum target -> `59 kB/s`

The same adaptive state also drives WireGuard `tc` shaping.

Shared state file:

- `/run/adaptive-upload-policy/state.json`

The main active fields are the adaptive target, reason, timestamps, and
`transmission_upload_limit_kbps`.

### 2. Native Transmission Tracker Prioritization

Transmission is patched to honor `TR_TRACKER_PRIORITY_FILE`.

Current behavior:

- preferred tracker hosts are loaded from that file
- already-due announces for preferred trackers are dispatched first
- peers learned from preferred trackers are treated as preferred in peer
  scheduling
- tracker-provided announce cadence is not overridden

This is now the main private-tracker preference mechanism.

## Optional Helper

Implementation:

- [pkgs/transmission-tracker-prioritizer/main.py](../pkgs/transmission-tracker-prioritizer/main.py)

If re-enabled, the helper only:

- classifies torrents by preferred tracker host when deciding which priorities
  to enforce
- sets:
  - preferred torrents -> `bandwidthPriority = high`
  - non-preferred incomplete or under-target torrents -> `bandwidthPriority = normal`
  - non-preferred completed torrents with
    `uploadRatio >= 3.0` -> `bandwidthPriority = low`
- exports `low` / `normal` / `high` torrent priority metrics based on current
  `bandwidthPriority`

It does **not**:

- create or manage a public bandwidth group
- split upload budget into “public” and “private” areas
- read SABnzbd exporter state
- read adaptive upload state

## Observability

Primary places to inspect the system:

- `/run/adaptive-upload-policy/state.json`
- logs:
  - `jellyfin-upload-policy`
  - `jellyfin-upload-policy-transmission`
  - `jellyfin-upload-policy-tc`

If the optional helper is re-enabled, it also exports per-priority torrent,
peer, download, and upload metrics through the node exporter textfile
directory.

Important note:

- `host_observability_transmission_public_group_upload_limit_bytes_per_second`
- `host_observability_transmission_observed_public_group_upload_limit_bytes_per_second`
- `host_observability_transmission_reserved_private_upload_bytes_per_second`

are now compatibility metrics only. The simplified helper exports them as `0`.

The obsolete `Public Upload Cap` and `Private Upload Reserve` Grafana panels
were removed from the `Media Pipe` dashboard.

## Related Files

- [pkgs/adaptive-upload-controller/main.py](../pkgs/adaptive-upload-controller/main.py)
- [pkgs/transmission-tracker-prioritizer/main.py](../pkgs/transmission-tracker-prioritizer/main.py)
- [nixos/srvarrvm/adaptive-upload-policy.nix](../nixos/srvarrvm/adaptive-upload-policy.nix)
- [nixos/srvarrvm/default.nix](../nixos/srvarrvm/default.nix)
- [nixos/srvarrvm/transmission-tracker-prioritizer.nix](../nixos/srvarrvm/transmission-tracker-prioritizer.nix)
- [overlays/default.nix](../overlays/default.nix)
