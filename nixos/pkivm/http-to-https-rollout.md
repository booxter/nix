# HTTP To HTTPS Rollout

## Goal

Move remaining LAN-facing HTTP service endpoints to HTTPS with the internal PKI.

This document is the execution checklist for that work.

Current status:

- shared internal HTTPS host pattern is implemented
- internal service cert issuance app is implemented
- UniFi DNS sync can publish service aliases from inventory
- `glance.home.arpa` is live on internal HTTPS
- `grafana.home.arpa` is live on internal HTTPS
- Darwin installs the internal root CA into the macOS System keychain
- Darwin Firefox imports enterprise roots for the internal PKI

Out of scope:

- loopback-only HTTP between processes on the same host
- public ACME ingress that is already HTTPS at the edge
- non-HTTP protocols such as NUT

## Target Shape

- Client-facing LAN services use HTTPS.
- Canonical internal service names live under `home.arpa`.
- Internal TLS server certs come from the internal CA on `prox-pkivm`.
- Reverse proxies terminate TLS and forward to loopback upstreams.
- Plain LAN ports are closed after each service is cut over.
- Beast public ingress proxies to internal HTTPS backends, not plain HTTP.

## Canonical Naming

Prefer dedicated service names on `443`, not hostnames with app-specific ports.

Planned internal names:

- `nix-cache.home.arpa`
- `grafana.home.arpa`
- `glance.home.arpa`
- `radarr.home.arpa`
- `sonarr.home.arpa`
- `lidarr.home.arpa`
- `bazarr.home.arpa`
- `prowlarr.home.arpa`
- `transmission.home.arpa`
- `sabnzbd.home.arpa`

Existing public HTTPS names stay as-is:

- `jf.ihar.dev`
- `js.ihar.dev`
- `mu.ihar.dev`
- `au.ihar.dev`
- `shelf.ihar.dev`
- `vi.ihar.dev`

## Service Groups

### Group 1: Cache

- `nix-cache` / `atticd`

Why:

- clients currently talk to the cache over plain HTTP
- Attic token traffic should not stay on plain LAN HTTP

Required changes:

- front `atticd` with internal HTTPS
- update Nix substituter URL
- update Attic client endpoint URL
- keep `nix-cache.home.arpa` as the canonical name

### Group 2: Internal Dashboards

- Grafana on `prox-fanavm`
- Glance on `prox-srvarrvm`

Required changes:

- add internal HTTPS vhosts
- update inventory/UI links to the HTTPS names
- update blackbox probes to HTTPS
- close the plain LAN ports afterward

Status:

- Glance is complete
- Grafana is complete

### Group 3: Internal Media/Admin UIs

- Radarr
- Sonarr
- Lidarr
- Bazarr
- Prowlarr
- Transmission
- SABnzbd

Required changes:

- add internal DNS aliases
- front each service with HTTPS on `443`
- bind app upstreams to loopback or private ports
- update service catalog and probes to the HTTPS names
- close the direct plain app ports afterward

### Group 4: Existing Public Services With Plain Internal Backend Hops

- Jellyseerr
- Aurral
- Audiobookshelf
- Shelfmark
- Vikunja

Required changes:

- switch beast public nginx upstreams from plain HTTP to internal HTTPS
- use internal service names and internal PKI validation
- keep public client URLs unchanged

### Group 5: Plain LAN Ports To Retire

- Jellyfin `:8096`
- Vikunja direct LAN port
- any remaining direct `srvarr` app ports after Groups 3 and 4

## Shared Implementation Work

### 1. Reusable Internal HTTPS Service Pattern

Implement a shared host-side pattern for client-facing internal HTTPS services:

- server cert + key from `sops`
- nginx vhost on `443`
- upstream to `127.0.0.1`
- optional websocket support
- optional auth hardening later

Reuse the current internal PKI issuance flow where possible.

### 2. DNS / Inventory

Inventory should be the source of truth for internal HTTPS service names.

Needed work:

- add internal service aliases to inventory
- render DNS records for those aliases
- keep `unifi-sync` responsible for pushing them to UniFi
- update service URLs and probe URLs to the HTTPS names

### 3. Cert Issuance

Extend or reuse the current issuance app so service certs can be issued with:

- host
- service name
- secret prefix
- SAN list

The desired flow is the same as current observability cert issuance:

- issue from `prox-pkivm`
- write into host secret
- deploy host

## Execution Order

### Phase 0: Prereqs

- verify the internal PKI root is trusted on every client that will hit these services
- done: inventory schema for internal service aliases
- done: reusable internal HTTPS host pattern
- done: matching cert issuance path
- done: Darwin System keychain trust for the internal root CA
- done: Firefox trust of the internal root CA on Darwin

### Phase 1: Cache

- add HTTPS in front of `atticd`
- switch:
  - `common/_mixins/nix/default.nix`
  - `common/_mixins/attic/default.nix`
- validate Nix substitution and Attic push over HTTPS

### Phase 2: Dashboards

- done: move Grafana to `https://grafana.home.arpa`
- done: move Glance to `https://glance.home.arpa`
- update service catalog and probes
- close plain LAN access

### Phase 3: Internal `srvarr` UIs

- introduce HTTPS for:
  - `radarr.home.arpa`
  - `sonarr.home.arpa`
  - `lidarr.home.arpa`
  - `bazarr.home.arpa`
  - `prowlarr.home.arpa`
  - `transmission.home.arpa`
  - `sabnzbd.home.arpa`
- update Glance and blackbox probes
- close direct HTTP access

Current note:

- Bazarr is the one exception in this group for now: the current NixOS module
  via `nixarr` only passes `--config`, `--port`, and `--no-update`, with no
  host/bind-address option, so the immediate rollout uses firewall closure
  plus HTTPS fronting rather than a true loopback bind. This should be cleaned
  up later, ideally by contributing the missing knob upstream.

### Phase 4: Beast Backend Hops

- switch beast public nginx upstreams to internal HTTPS backends
- verify public apps still work:
  - `js.ihar.dev`
  - `mu.ihar.dev`
  - `au.ihar.dev`
  - `shelf.ihar.dev`
  - `vi.ihar.dev`

### Phase 5: Final Plain-Port Cleanup

- retire Jellyfin plain LAN access if not needed
- retire remaining plain app ports
- verify remaining intentional HTTP is loopback-only

## Beast Constraint

Changes that touch beast ingress or Jellyfin-adjacent nginx need a maintenance window.

Do not combine beast work with the earlier phases unless needed. The preferred order is:

1. cache
2. dashboards
3. internal `srvarr` UIs
4. beast backend hop migration
5. final beast plain-port cleanup

## Validation Checklist

For each phase:

- DNS resolves the new HTTPS name correctly
- the server presents the expected internal PKI cert
- the browser and CLI trust the chain without manual overrides
- old HTTP endpoint is either redirected or closed, depending on the phase
- blackbox probes are green
- Grafana service board reflects the new canonical URL
- public user-visible behavior is unchanged where applicable

## End State

When this plan is complete:

- non-loopback HTTP should be gone for normal LAN service access
- the only remaining plain HTTP should be host-local traffic
- public ingress on beast should terminate to HTTPS backends
- cache traffic and internal UI access should use internal PKI by default
