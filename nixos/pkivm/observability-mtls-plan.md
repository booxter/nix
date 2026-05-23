# Observability mTLS Plan

## Scope

This plan covers migrating the remaining remote Prometheus scrapes for
NixOS-hosted services to mTLS.

Current exclusions:

- loopback-only scrapes on `prox-fanavm`
- Darwin scrapes such as `mmini`
- UPS / NUT jobs that Prometheus reaches through the local exporter on `fana`

The target model is:

- `prox-fanavm` keeps using its existing Prometheus client certificate
- every remote NixOS-hosted scrape endpoint requires client-cert auth
- Prometheus talks to those endpoints over `https`

## Current Remote Scrapes Without mTLS

### Remote node scrape still plain

- `node`
  - `mmini:9100`
  - Darwin, out of scope for this phase

### Remote blackbox exporters

- `blackbox-icmp`
  - `beast:9115`
  - `frame:9115`
- `blackbox-tcp`
  - `beast:9115`
  - `frame:9115`

### Remote service exporters and app metrics

- `smartctl`
  - `beast:9633`
- `jellyfin`
  - `beast:9594`
- `sabnzbd`
  - `prox-srvarrvm:9387`
- `vikunja`
  - `prox-orgvm:3456`

## Already Using mTLS

- `node-mtls`
  - `beast`
  - `frame`
  - `pi5`
  - `prox-builder1vm`
  - `prox-builder2vm`
  - `prox-builder3vm`
  - `prox-cachevm`
  - `prox-gwvm`
  - `prox-orgvm`
  - `prox-pkivm`
  - `prox-srvarrvm`
  - `prx1-lab`
  - `prx2-lab`
  - `prx3-lab`

This means the internal PKI and Prometheus client certificate flow already work
for node exporter and should be reused.

## Desired End State

- `prox-fanavm` has only:
  - local loopback HTTP scrapes
  - remote HTTPS scrapes with client-cert auth
- no remote NixOS exporter or app metrics endpoint is scraped over plain HTTP
- mTLS secret handling stays host-local through `sops`
- Prometheus scrape config generation stays declarative from host config

## Maintenance Window Constraint

`beast` changes are postponed for now.

Anything that touches `beast` for this migration needs a separate maintenance
window, so the first implementation phase should avoid deploying `beast`.

## Implementation Strategy

### 1. Reusable mTLS server helper for non-node endpoints

Add a reusable mixin or helper that can:

- install per-host server cert and key from `sops`
- render a small web config or reverse-proxy config
- expose a stable `https` endpoint with:
  - server cert
  - `RequireAndVerifyClientCert`
  - internal PKI CA as client CA

For Prometheus exporters that already support the exporter-toolkit
`--web.config.file` pattern, prefer that over an extra reverse proxy.

For services that do not support exporter-toolkit natively, front them with a
small local reverse proxy bound to the LAN address and keep the upstream app on
loopback.

### 2. Extend host metadata so `fana` knows which jobs are mTLS

Today only node exporter has an mTLS flag.

Add service-specific metadata so `prox-fanavm` can split remote scrape targets
into:

- plain HTTP
- HTTPS with mTLS

The scrape generator should not hard-code hostnames and ports in multiple
places once these jobs move.

### 3. Convert service families in order

#### A. Blackbox exporter on `frame`

Why first:

- it already uses the shared observability client mixin
- the NixOS module exposes `services.prometheus.exporters.blackbox.extraFlags`
- this is a simple exporter endpoint, so it is the cleanest non-node migration
- it avoids `beast`, which is deferred to a dedicated maintenance window

Planned shape:

- enable exporter-toolkit style mTLS directly on blackbox exporter if supported
- otherwise front `127.0.0.1:9115` with a tiny mTLS reverse proxy
- update `blackboxProbeSourceConfigs` in `fana` to use `https://host:9115`

#### B. `sabnzbd` exporter on `prox-srvarrvm`

Planned shape:

- same decision as other exporters:
  - direct exporter-toolkit mTLS if supported
  - otherwise loopback exporter plus shared mTLS proxy

#### C. `vikunja` metrics on `prox-orgvm`

This is an application endpoint, not a Prometheus exporter.

Planned shape:

- keep Vikunja bound as it is or move metrics exposure to loopback if practical
- add a dedicated mTLS reverse proxy path for `/api/v1/metrics`
- update the `vikunja` scrape job in `fana` to use `https`

#### D. Deferred `beast` work

The following `beast` changes stay out of the first rollout and should be done
only during a dedicated maintenance window:

- blackbox exporter on `beast`
- `smartctl` exporter on `beast`
- `jellyfin` exporter on `beast`

Planned shape for the deferred `beast` work:

- blackbox exporter:
  - direct exporter-toolkit mTLS if supported
  - otherwise loopback exporter plus the shared mTLS proxy
- `smartctl` exporter:
  - direct exporter-toolkit mTLS if supported
  - otherwise loopback exporter plus the shared mTLS proxy

The `jellyfin` exporter is custom service wiring, not a stock NixOS exporter
module.

Planned shape:

- likely keep the exporter itself on loopback
- front it with the shared mTLS proxy on `9594`

## Suggested Rollout Order

1. Add the shared non-node mTLS server helper
2. Convert blackbox exporter on `frame`
3. Convert `sabnzbd` on `prox-srvarrvm`
4. Convert `vikunja` metrics on `prox-orgvm`
5. Schedule a separate maintenance window for all `beast` scraper changes
6. During that window, convert `beast` blackbox, `smartctl`, and `jellyfin`
7. Update `fana` scrape configs after each service family so Prometheus never
   expects HTTPS before the target is ready

## Secrets Impact

Each migrated NixOS host will need additional `sops` material for the new
endpoint if the existing node-exporter certificate is not reused.

Decision to make during implementation:

- either reuse one host-level observability server certificate for multiple
  exporter ports
- or issue distinct cert/key pairs per service endpoint

The simpler path is one host-level observability certificate reused across all
Prometheus-facing endpoints on that host.

## Open Questions

- Which exporter packages already support `--web.config.file` cleanly:
  - blackbox exporter
  - smartctl exporter
  - sabnzbd exporter
- Whether `vikunja` metrics should stay on the main app port or move behind a
  dedicated local proxy path
- Whether local loopback self-scrapes on `fana` should remain plain permanently
  or also be standardized later
