# `srvarr` Upload Policy

This document describes the current upload-control model on `srvarr`.

## Overview

There are two active control layers:

- adaptive global upload budgeting from Jellyfin playback
- helper-driven per-torrent FORCE priority inside the patched Transmission daemon

There is no public/private sub-cap split.

`transmission-tracker-prioritizer` is active on `srvarr`. It classifies torrents
by tracker host, sets torrent priority, and exports per-class metrics for
Prometheus / Grafana.

## Active Pieces

Host wiring:

- [nixos/srvarrvm/adaptive-upload-policy.nix](../nixos/srvarrvm/adaptive-upload-policy.nix)
- [nixos/srvarrvm/default.nix](../nixos/srvarrvm/default.nix)
- [overlays/default.nix](../overlays/default.nix)
- [nixos/srvarrvm/transmission-tracker-prioritizer.nix](../nixos/srvarrvm/transmission-tracker-prioritizer.nix)

Important current facts:

- `srvarr` imports `adaptive-upload-policy.nix`
- `srvarr` imports `transmission-tracker-prioritizer.nix`
- the preferred tracker host secret lives at:
  - `/run/secrets/transmissionTrackerHosts`
  - it is used by `transmission-tracker-prioritizer` and `transmission-torrent-cleaner`

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

### 2. Per-Torrent FORCE Priority

Current behavior:

- the helper loads preferred tracker hosts from `/run/secrets/transmissionTrackerHosts`
- torrents matching those hosts are set to `bandwidthPriority = FORCE`
- non-preferred downloading torrents are set to `bandwidthPriority = HIGH`
- non-preferred seeding torrents below ratio `3.0` are set to
  `bandwidthPriority = NORMAL`
- non-preferred seeding torrents at ratio `3.0+` are set to
  `bandwidthPriority = LOW`
- the patched Transmission daemon gives FORCE torrents first access to
  upload/download scheduling

This is now the main private-tracker preference mechanism.

## Helper

Implementation:

- [pkgs/transmission-tracker-prioritizer/main.py](../pkgs/transmission-tracker-prioritizer/main.py)

The helper:

- classifies torrents by preferred tracker host
- sets:
  - preferred torrents -> `bandwidthPriority = force`
  - non-preferred downloading torrents -> `bandwidthPriority = high`
  - non-preferred seeding torrents with ratio `< 3.0` -> `bandwidthPriority = normal`
  - non-preferred seeding torrents with ratio `>= 3.0` -> `bandwidthPriority = low`
- exports private/public class metrics

The `3.0` ratio threshold is shared with `transmission-torrent-cleaner`.

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
  - `transmission-tracker-prioritizer`

The helper exports per-class torrent, peer, download, and upload metrics
through the node exporter textfile directory.

The obsolete `Public Upload Cap` and `Private Upload Reserve` Grafana panels
were removed from the `Media Pipe` dashboard.

## Related Files

- [pkgs/adaptive-upload-controller/main.py](../pkgs/adaptive-upload-controller/main.py)
- [pkgs/transmission-tracker-prioritizer/main.py](../pkgs/transmission-tracker-prioritizer/main.py)
- [nixos/srvarrvm/adaptive-upload-policy.nix](../nixos/srvarrvm/adaptive-upload-policy.nix)
- [nixos/srvarrvm/default.nix](../nixos/srvarrvm/default.nix)
- [nixos/srvarrvm/transmission-tracker-prioritizer.nix](../nixos/srvarrvm/transmission-tracker-prioritizer.nix)
- [overlays/default.nix](../overlays/default.nix)
