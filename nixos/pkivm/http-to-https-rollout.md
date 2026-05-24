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

- switch `beast` public nginx upstreams from plain HTTP to internal HTTPS for:
  - `js.ihar.dev`
  - `mu.ihar.dev`
  - `au.ihar.dev`
  - `shelf.ihar.dev`
  - `vi.ihar.dev`
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

- `beast` ingress work still needs a maintenance window
