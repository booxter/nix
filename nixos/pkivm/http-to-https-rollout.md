# HTTP To HTTPS Rollout

This file only tracks the remaining HTTP-to-HTTPS work.

Already done:

- internal PKI trust on Darwin
- `glance.home.arpa`
- `grafana.home.arpa`
- internal HTTPS for `radarr`, `sonarr`, `lidarr`, `bazarr`, and `prowlarr`
- internal HTTPS for `tmission.home.arpa`
- internal HTTPS for `sabnzbd.home.arpa`

## Remaining Work

### 1. Cache

- put `atticd` behind internal HTTPS at `nix-cache.home.arpa`
- switch Nix substituter and Attic client URLs to HTTPS
- verify cache reads and pushes over HTTPS

### 2. Beast Backend Hops

- keep split DNS for the public names (`js.ihar.dev`, `mu.ihar.dev`, `au.ihar.dev`,
  `shelf.ihar.dev`)
- keep `beast` as the only WAN-facing ingress on `:443`
- move each backend app to a private internal HTTPS vhost on its origin host
- require mTLS on that backend hop:
  - `beast` presents a dedicated client cert for the backend service
  - the backend nginx vhost verifies that client cert against the internal PKI
- use the `vikunja` path as the reusable pattern:
  - public `vi.ihar.dev` stays on `beast`
  - backend `vikunja.home.arpa` is internal HTTPS+mTLS only
  - direct backend access without a client cert returns `400`
- switch the remaining `beast` public nginx upstreams from plain HTTP to internal
  HTTPS+mTLS for:
  - `js.ihar.dev`
  - `mu.ihar.dev`
  - `au.ihar.dev`
  - `shelf.ihar.dev`
- validate public behavior stays unchanged

### 3. Final Plain-Port Cleanup

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
