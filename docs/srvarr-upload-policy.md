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
- idle uplink ceiling with no remote playback: `24mbit`
- minimum computed target with healthy exporter data: `2mbit`
- conservative fallback target on exporter failure: `8mbit`
- remote media stream bitrate safety headroom: `20%`
- Jellyfin exporter request timeout: `10s`
- Transmission RPC timeout:
  - adaptive applier: `20s`
  - tracker prioritizer: `20s`
- preferred tracker match refresh: `60s`
- public-group relaxation hold time: `45s`
- minimum preferred-torrent reserve while preferred uploads are active: `10%`
- preferred upload rate headroom for public-cap derivation: `30%`

Derived limits:

- Transmission session upload limit = `95%` of the selected target
- public torrent group bootstrap limit = `50%` of the current Transmission
  limit while preferred uploads are active

Examples:

- `24mbit` target -> Transmission `2850 kB/s`, public-group bootstrap `1425 kB/s`
- `15mbit` target -> Transmission `1781 kB/s`, public-group bootstrap `890 kB/s`
- `8mbit` fallback -> Transmission `950 kB/s`, public-group bootstrap `475 kB/s`
- `2mbit` minimum computed target -> Transmission `237 kB/s`,
  public-group bootstrap `118 kB/s`

## Inputs

### Jellyfin Exporter

The decider reads the exporter metrics endpoint on `beast`.

It counts active media playback sessions and requires per-session bitrate
data:

- media types:
  - `audio`
  - `audiobook`
  - `episode`
  - `movie`
  - `musicvideo`
  - `trailer`
  - `video`
- only `jellyfin_now_playing_state > 0.5` counts as active playback

The bitrate-aware logic depends on three exporter metrics:

- `jellyfin_now_playing_state`
- `jellyfin_now_playing_bitrate_bits_per_second`
- `jellyfin_user_active`

It also tries to ignore LAN/local viewers by correlating:

- `jellyfin_now_playing_state`
- `jellyfin_now_playing_bitrate_bits_per_second`
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

### Bitrate Budgeting

The observed target is derived from summed active remote media bitrate, not
just stream count:

1. sum `jellyfin_now_playing_bitrate_bits_per_second` for all active external
   media sessions
2. add `20%` headroom to that total
3. subtract the reserved amount from the `24mbit` idle ceiling
4. clamp the result to the healthy-exporter range `[2, 24]`
5. round the resulting target to `0.1mbit`

In formula form:

- `reserved_mbit = remote_media_bitrate_mbit * 1.2`
- `target_mbit = clamp(2, 24, 24 - reserved_mbit)`

Examples:

- no external media playback -> `24mbit`
- one remote `4mbit` stream -> reserve `4.8mbit` -> target `19.2mbit`
- two remote streams totaling `10mbit` -> reserve `12mbit` -> target `12mbit`
- a very high bitrate session that would leave less than `2mbit` -> clamp to
  `2mbit`

If any active external media session is missing bitrate data, the exporter is
still reachable, so the decider stays aggressive and clamps to the minimum
computed target of `2mbit`.

### Tightening

When observed demand goes up, the effective state tightens immediately.

Examples:

- `24 -> 19.2`
- `19.2 -> 12`
- any target -> `8` when exporter becomes unreachable
- any target -> `2` when an active external media session is missing bitrate

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
- `active_external_media_streams`
- `active_external_media_bitrate_bits_per_second`
- `active_media_streams_total`
- `missing_external_media_bitrate_sessions`
- `reserved_external_media_bandwidth_mbit`
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

When preferred uploads are active, the cap is no longer a fixed `50%` split.
Instead:

1. the adaptive policy state provides the current Transmission session limit
   plus a conservative bootstrap public-group cap equal to `50%` of that limit
2. the tracker prioritizer sums current `rateUpload` across preferred torrents
3. it derives an observed public cap by reserving the larger of:
   - `10%` of the current Transmission limit
   - `130%` of the currently observed preferred upload rate
4. if that observed cap is tighter than the current applied cap, it tightens
   immediately
5. if that observed cap is more generous, it waits `45s` before relaxing
   upward

This keeps the system conservative when preferred uploads first appear, but
lets public torrents reclaim bandwidth when preferred leechers stay slow.

This gives the desired behavior:

- reserve capacity for private torrents only when they are actually using it
- otherwise let public torrents borrow the headroom

## Failure Behavior

The system is designed to fail conservative.

If Jellyfin exporter fails:

- decider writes the conservative `8mbit` floor

If active external media playback is detected but bitrate data is missing for
one or more of those sessions:

- decider writes the aggressive minimum computed target of `2mbit`

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
- The bitrate-based decider assumes the deployed exporter exposes
  `jellyfin_now_playing_bitrate_bits_per_second`. If that metric disappears,
  the policy will fall back to the conservative floor while remote playback is
  active.
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
