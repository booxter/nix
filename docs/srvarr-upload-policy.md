# `srvarr` Upload Policy

This document describes the adaptive upload policy on `srvarr`: how Jellyfin
viewer activity affects the WireGuard upload budget, how Transmission is kept
in sync with that budget, and how private-tracker torrents are favored within
the remaining Transmission bandwidth.

## Goals

- keep `srvarr` conservative when Jellyfin is actively streaming over the WAN
- let torrents use more of the uplink when Jellyfin is idle
- favor uploads for selected private trackers over public torrents
- make the decision logic observable and easy to debug
- fail safe when upstream signals are missing or stale

## High-Level Design

The design is split into one decider and several enforcers:

- `jellyfin-upload-policy`
  - polls Jellyfin exporter metrics from `beast`
  - computes the desired upload tier
  - writes the shared state file at `/run/adaptive-upload-policy/state.json`

- `jellyfin-upload-policy-transmission`
  - reads the shared state file
  - applies the Transmission session upload cap via RPC

- `jellyfin-upload-policy-tc`
  - reads the shared state file
  - applies the WireGuard upload shaping rate with `tc`

- `transmission-tracker-prioritizer`
  - reads a secret list of tracker hosts to prefer
  - marks matching torrents as high priority
  - puts all other torrents into a managed public bandwidth group
  - scales that public group cap from the same shared state file

The key design choice is that only the decider talks to Jellyfin exporter.
Everything else consumes the local state file. This keeps policy computation in
one place and makes it possible to inspect the effective decision directly.

## Current Wiring

Host wiring lives in:

- [nixos/srvarrvm/adaptive-upload-policy.nix](../nixos/srvarrvm/adaptive-upload-policy.nix)
- [nixos/srvarrvm/transmission-tracker-prioritizer.nix](../nixos/srvarrvm/transmission-tracker-prioritizer.nix)

Current values:

- decider poll interval: `20s`
- applier poll interval: `5s`
- stale state cutoff for appliers: `60s`
- relaxation hold time: `300s`
- Jellyfin exporter request timeout: `10s`
- Transmission RPC timeout:
  - adaptive applier: `20s`
  - tracker prioritizer: `20s`
- preferred tracker match refresh: `60s`

Current tier mapping:

- `0` external active video streams -> `20mbit`
- `1` external active video stream -> `15mbit`
- `2+` external active video streams -> `8mbit`
- exporter failure -> `8mbit`

Derived limits:

- Transmission session upload limit = `95%` of the selected tier
- public torrent group upload limit = `50%` of the current Transmission limit

Examples:

- `20mbit` tier -> Transmission `2375 kB/s`, public group `1187 kB/s`
- `15mbit` tier -> Transmission `1781 kB/s`, public group `890 kB/s`
- `8mbit` tier -> Transmission `950 kB/s`, public group `475 kB/s`

## Inputs

### Jellyfin Exporter

The decider reads the exporter metrics endpoint on `beast`.

It counts only active video playback sessions:

- media types:
  - `episode`
  - `movie`
  - `musicvideo`
  - `trailer`
  - `video`
- only `jellyfin_now_playing_state > 0.5` counts as active playback

It also tries to ignore LAN/local viewers by correlating:

- `jellyfin_now_playing_state`
- `jellyfin_user_active`

and treating these client addresses as internal:

- RFC1918 IPv4
- IPv6 ULA
- loopback
- link-local
- reserved addresses

So the adaptive policy reacts only to viewers that appear to be consuming the
limited uplink, not to local LAN playback.

### Private Tracker Host List

Preferred trackers are stored as a sops secret and read from:

- `/run/secrets/transmissionTrackerHosts`

The tracker prioritizer reloads this file every loop. Each line may be a host
or a full announce URL. Matching is normalized to the tracker host name.

## Decision Model

Implementation lives in:

- [pkgs/adaptive-upload-controller/main.py](../pkgs/adaptive-upload-controller/main.py)

The decider computes two states:

- observed state
  - what Jellyfin exporter says right now
- effective state
  - what the host should enforce right now

This split exists to support hysteresis.

### Tightening

When observed demand goes up, the effective state tightens immediately.

Examples:

- `20 -> 15`
- `15 -> 8`
- any tier -> `8` when exporter becomes unreachable

### Relaxing

When observed demand goes down, the effective state does not relax
immediately. Instead:

1. the decider records the lower target as a pending relaxation
2. it keeps enforcing the stricter current tier
3. if the lower observed target remains stable for `300s`, it relaxes
4. if demand rises again before the hold expires, the pending relaxation is
   dropped

This avoids flapping when Jellyfin sessions briefly disappear and reappear.

### Shared State File

The decider writes the full effective policy to:

- `/run/adaptive-upload-policy/state.json`

Important fields:

- `observed_target_mbit`
- `target_mbit`
- `reason`
- `observed_reason`
- `active_external_video_streams`
- `active_video_streams_total`
- `transmission_upload_limit_kbps`
- `public_group_upload_limit_kbps`
- `target_tc_rate`
- `relaxation_pending_target_mbit`
- `relaxation_pending_since`
- `updated_at`

`target_*` fields are the ones enforcers should obey. `observed_*` fields are
there for debugging.

## Enforcers

### Transmission Session Cap

The Transmission applier uses RPC `session-set` to keep:

- `speed-limit-up`
- `speed-limit-up-enabled`

aligned with `transmission_upload_limit_kbps` from the state file.

This is important because Transmission's own scheduler only meaningfully
arbitrates torrent priority when Transmission itself sees a constrained upload
budget. If only an external `tc` shaper exists, Transmission's torrent
priority bias becomes much weaker.

### WireGuard `tc` Shaping

The `tc` applier updates the existing shaping tree in place:

- `tc class change ... classid 1:10 htb rate ... ceil ...`
- `tc qdisc change ... parent 1:10 handle 10: cake bandwidth ...`

Earlier revisions rebuilt the entire tree on every tier change. That caused a
brief unshaped window and visible upload spikes during transitions. The
current in-place `change` approach avoids that.

### Transmission Tracker Prioritization

Implementation lives in:

- [pkgs/transmission-tracker-prioritizer/main.py](../pkgs/transmission-tracker-prioritizer/main.py)

Policy:

- if a torrent has at least one tracker host from the preferred list:
  - set `bandwidthPriority = high`
  - clear its bandwidth group

- otherwise:
  - set `bandwidthPriority = normal`
  - put it in group `public-low-priority`

This service is intentionally stateless. On every loop it fully owns those two
fields for all torrents.

The managed public group cap is enabled only when any preferred torrent is
actively uploading. When no preferred torrents are actively uploading, the
group cap is disabled so public torrents can use the full current Transmission
budget.

This gives the desired behavior:

- reserve capacity for private torrents only when they are actually using it
- otherwise let public torrents borrow the headroom

## Failure Behavior

The system is designed to fail conservative.

If Jellyfin exporter fails:

- decider writes the conservative `8mbit` tier

If the state file is missing, invalid, or stale:

- Transmission applier falls back to the conservative tier
- `tc` applier falls back to the conservative tier

If Transmission RPC hangs:

- the appliers log and skip that iteration
- they retry on the next loop

If the tracker secret is missing:

- the tracker prioritizer logs and skips that iteration
- it retries on the next loop

## Observability

There are two main ways to inspect the system:

- the shared state file
  - `/run/adaptive-upload-policy/state.json`
- service logs
  - `jellyfin-upload-policy`
  - `jellyfin-upload-policy-transmission`
  - `jellyfin-upload-policy-tc`
  - `transmission-tracker-prioritizer`

The tracker prioritizer also exports Prometheus textfile metrics for private
vs public torrent counts and peer counts. These are used in Grafana to compare
private/public upload demand against WAN outbound bandwidth.

## Practical Latency

With the current polling values:

- tighten latency:
  - best case: a few seconds
  - worst case: about `25s`
- relax latency:
  - worst case: about `5m25s`

That comes from:

- `20s` decider polling
- `5s` applier polling
- `300s` relaxation hold

## Tradeoffs and Limitations

- LAN-vs-WAN detection depends on Jellyfin exporter exposing the real client IP
  and not only a reverse proxy address.
- Tracker prioritization is torrent-level, not tracker-level. If a torrent has
  a preferred tracker, the whole torrent is boosted.
- Public deprioritization uses both a soft bias (`bandwidthPriority`) and a
  hard group cap. The hard cap is what makes the private/public separation
  noticeable under contention.
- The `tc` and Transmission caps are intentionally kept aligned so that both
  the kernel shaper and Transmission scheduler see the same budget.

## Related Files

- [pkgs/adaptive-upload-controller/default.nix](../pkgs/adaptive-upload-controller/default.nix)
- [pkgs/adaptive-upload-controller/main.py](../pkgs/adaptive-upload-controller/main.py)
- [pkgs/transmission-tracker-prioritizer/default.nix](../pkgs/transmission-tracker-prioritizer/default.nix)
- [pkgs/transmission-tracker-prioritizer/main.py](../pkgs/transmission-tracker-prioritizer/main.py)
- [nixos/srvarrvm/adaptive-upload-policy.nix](../nixos/srvarrvm/adaptive-upload-policy.nix)
- [nixos/srvarrvm/transmission-tracker-prioritizer.nix](../nixos/srvarrvm/transmission-tracker-prioritizer.nix)
