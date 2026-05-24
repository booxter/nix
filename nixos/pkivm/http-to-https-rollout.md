# HTTP To HTTPS Rollout

This file only tracks the remaining HTTP-to-HTTPS work.

Already done:

- internal PKI trust on Darwin
- `nix-cache.home.arpa` for Nix substituters and Attic push
- `glance.home.arpa`
- `grafana.home.arpa`
- `loki.home.arpa` with mTLS log shipping from non-work NixOS hosts
- internal HTTPS for `radarr`, `sonarr`, `lidarr`, `bazarr`, and `prowlarr`
- internal HTTPS for `tmission.home.arpa`
- internal HTTPS for `sabnzbd.home.arpa`
- backend mTLS for the public `beast` ingress:
  - `js.ihar.dev`
  - `mu.ihar.dev`
  - `au.ihar.dev`
  - `shelf.ihar.dev`
  - `vi.ihar.dev`

## Remaining Work

### 1. Final Plain-Port Cleanup

- retire Jellyfin plain LAN access on `:8096` if it is no longer needed
- verify that intentional HTTP is loopback-only

## Follow-Up Cleanup

- Bazarr still does not bind to loopback cleanly through `nixarr`
- current state is acceptable because plain LAN access is closed by firewall
  and the UI is fronted by HTTPS
- later, upstream a bind-address / host knob and switch Bazarr to a true
  loopback-only bind

## Constraint

- check for active Jellyfin playback on `beast` before any deploy that restarts
  `nginx`
