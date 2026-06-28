# `srvarr` Upload Policy

This document describes the current upload-control model on `srvarr`.

## Overview

There are two active control layers:

- adaptive global upload budgeting from Jellyfin playback
- helper-driven per-torrent priority from preferred tracker hosts

There is no public/private sub-cap split.

`transmission-prioritizer` is also active on `srvarr`, but it is now
split into two services:

- `transmission-prioritizer`: applies `bandwidth_priority` changes
- `transmission-collector`: exports Prometheus metrics without mutating torrents

Together they:

- mark preferred torrents `bandwidth_priority = high`
- if any preferred torrent currently has peers actively downloading from us,
  keep non-preferred
  torrents at `bandwidth_priority = normal` while `upload_ratio < 3.0` and
  demote the rest to `bandwidth_priority = low`
- if no preferred torrent currently has peers actively downloading from us,
  promote non-preferred
  torrents with
  `upload_ratio < 3.0` to `bandwidth_priority = high` and keep
  `upload_ratio >= 3.0` torrents at `bandwidth_priority = low`
- if a completed non-preferred torrent reaches `upload_ratio >= 6.0`, pause it
  so the cleaner can remove it once it is old enough
- exports per-class metrics for Prometheus / Grafana

It does not manage bandwidth groups, public caps, or SABnzbd suppression.

## Active Pieces

Host wiring:

- [adaptive-upload-policy.nix](./adaptive-upload-policy.nix)
- [default.nix](./default.nix)
- [overlays/default.nix](../../overlays/default.nix)

Helper module:

- [transmission-prioritizer.nix](./transmission-prioritizer.nix)

Important current facts:

- `srvarr` imports `adaptive-upload-policy.nix`
- `srvarr` imports `transmission-prioritizer.nix`
- `transmission-prioritizer` can be stopped independently from
  `transmission-collector`
- the preferred tracker host secret lives at:
  - `/run/secrets/transmissionTrackerHosts`
- the prioritizer, collector, and torrent cleaner receive that secret with
  `--trackers-file`

## Current Behavior

### 1. Adaptive Global Cap

`jellyfin-upload-policy` reads Jellyfin exporter metrics from `beast` over the
internal Prometheus mTLS endpoint on `https://beast:9594/metrics` and computes
a host-wide upload target.

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

### 2. Helper-Driven Tracker Prioritization

Transmission itself is unpatched for tracker preference. The local helper
services classify torrents by preferred tracker host through Transmission RPC
and enforce `bandwidth_priority` on whole torrents.

Current behavior:

- preferred tracker hosts are loaded from `/run/secrets/transmissionTrackerHosts`
- preferred torrents are kept at `bandwidth_priority = high`
- non-preferred torrents are promoted, normalized, demoted, or stopped according
  to preferred-torrent activity and ratio thresholds
- tracker announce cadence and peer identity stay under upstream Transmission
  behavior

This is the main private-tracker preference mechanism.

## Helper Services

Implementation:

- [pkgs/transmission-tracker-prioritizer/prioritizer.py](./pkgs/transmission-tracker-prioritizer/prioritizer.py)
- [pkgs/transmission-tracker-prioritizer/collector.py](./pkgs/transmission-tracker-prioritizer/collector.py)
- [pkgs/transmission-tracker-prioritizer/main.py](./pkgs/transmission-tracker-prioritizer/main.py)

The helper code is split into separate collector and prioritizer entrypoints
with shared classification logic:

- `transmission-prioritizer`: classifies torrents and writes
  `bandwidth_priority` updates back to Transmission
- `transmission-collector`: runs the same classification logic but only exports
  the observed state to Prometheus
- both classify torrents by preferred tracker host when deciding which
  priorities to enforce
- sets:
  - preferred torrents -> `bandwidth_priority = high`
  - if any preferred torrent currently has peers actively downloading from us:
    `non-preferred torrents with upload_ratio < 3.0 -> bandwidth_priority = normal`
  - if any preferred torrent currently has peers actively downloading from us:
    `non-preferred torrents with upload_ratio >= 3.0 -> bandwidth_priority = low`
  - if no preferred torrent currently has peers actively downloading from us:
    `non-preferred torrents with upload_ratio < 3.0 -> bandwidth_priority = high`
  - if no preferred torrent currently has peers actively downloading from us:
    `non-preferred torrents with upload_ratio >= 3.0 -> bandwidth_priority = low`
  - if a non-preferred torrent is complete and `upload_ratio >= 6.0`:
    stop/pause the torrent
- exports `low` / `normal` / `high` torrent priority metrics based on current
  `bandwidth_priority`

It does **not**:

- create or manage a public bandwidth group
- split upload budget into “public” and “private” areas
- read SABnzbd exporter state
- read adaptive upload state

## Observability

Primary places to inspect the system:

- `/run/adaptive-upload-policy/state.json`
- mTLS client material:
  - `/run/secrets/jellyfinUploadPolicyClientCrt`
  - `/run/secrets/jellyfinUploadPolicyClientKey`
- logs:
  - `jellyfin-upload-policy`
  - `jellyfin-upload-policy-transmission`
  - `jellyfin-upload-policy-tc`

The collector exports per-priority torrent, peer, download, and upload metrics
through the node exporter textfile directory.

On `srvarr`, that export is handled by
`transmission-collector`, so metrics continue updating even if
`transmission-prioritizer` is stopped.

Important note:

- `host_observability_transmission_public_group_upload_limit_bytes_per_second`
- `host_observability_transmission_observed_public_group_upload_limit_bytes_per_second`
- `host_observability_transmission_reserved_private_upload_bytes_per_second`

are now compatibility metrics only. The simplified helper exports them as `0`.

The obsolete `Public Upload Cap` and `Private Upload Reserve` Grafana panels
were removed from the `Media Pipe` dashboard.

## Related Files

- [pkgs/adaptive-upload-controller/main.py](./pkgs/adaptive-upload-controller/main.py)
- [pkgs/transmission-tracker-prioritizer/prioritizer.py](./pkgs/transmission-tracker-prioritizer/prioritizer.py)
- [pkgs/transmission-tracker-prioritizer/collector.py](./pkgs/transmission-tracker-prioritizer/collector.py)
- [pkgs/transmission-tracker-prioritizer/main.py](./pkgs/transmission-tracker-prioritizer/main.py)
- [adaptive-upload-policy.nix](./adaptive-upload-policy.nix)
- [default.nix](./default.nix)
- [transmission-prioritizer.nix](./transmission-prioritizer.nix)
- [overlays/default.nix](../../overlays/default.nix)
