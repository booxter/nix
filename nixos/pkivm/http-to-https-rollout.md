# HTTP To HTTPS Rollout

This file only tracks the remaining HTTP-to-HTTPS work.

Already done:

- internal PKI trust on Darwin
- `glance.home.arpa`
- `grafana.home.arpa`
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

### 1. Cache

Transition plan:

1. Add `https://nix-cache.home.arpa` in front of `atticd`, but keep the current
   LAN HTTP endpoint alive.
2. Move Attic push clients to the HTTPS endpoint first.
3. Verify there is no remaining HTTP push traffic.
4. Only then decide whether to keep HTTP read-only for pull or move pull to
   HTTPS too.

Current implementation target:

- `atticd` reachable on both:
  - `http://nix-cache:8080`
  - `https://nix-cache.home.arpa`
- pull clients check both substituters, preferring HTTPS and falling back to
  HTTP during transition
- push clients still unchanged until the dual-endpoint server is live

### 2. Final Plain-Port Cleanup

- retire Jellyfin plain LAN access on `:8096` if it is no longer needed
- retire any remaining direct LAN HTTP app ports
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
