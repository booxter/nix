# Observability mTLS

## Scope

This document covers the non-node Prometheus scrapes that are now wired for
mTLS in NixOS config.

Current exclusions:

- loopback-only scrapes on `prox-fanavm`
- Darwin scrapes such as `mmini`
- UPS / NUT jobs that Prometheus reaches through the local exporter on `fana`

Rollout is still pending. This file describes the implemented shape in the repo
and the remaining deployment order.

## Implemented Shape

### Shared host-side mTLS endpoint model

Remote NixOS scrapes now use a shared host-side abstraction:

- host metadata lives under
  `host.observability.client.prometheusMtlsEndpoints`
- each endpoint declares:
  - LAN-visible port
  - scrape path
  - local upstream URL
  - `sops` secret prefix for the server certificate and key
- nginx fronts each endpoint with:
  - HTTPS
  - client-certificate auth
  - the internal PKI root as client CA

The shared implementation lives in:

- [nixos/_mixins/observability-client/default.nix](../_mixins/observability-client/default.nix)

### Prometheus client certificate reuse

`prox-fanavm` still uses the existing Prometheus client certificate that was
already in place for `node-mtls`.

That same client cert/key is now also used for:

- `smartctl`
- `jellyfin`
- `sabnzbd`
- `vikunja`
- remote `blackbox-icmp`
- remote `blackbox-tcp`

## Implemented Endpoints

### `frame`

- `blackbox`
  - public mTLS endpoint: `https://frame:9115/probe`
  - local upstream: `http://127.0.0.1:19115/probe`
  - secret prefix: `prometheus/blackbox`

### `beast`

- `blackbox`
  - public mTLS endpoint: `https://beast:9115/probe`
  - local upstream: `http://127.0.0.1:19115/probe`
  - secret prefix: `prometheus/blackbox`
- `smartctl`
  - public mTLS endpoint: `https://beast:9633/metrics`
  - local upstream: `http://127.0.0.1:19633/metrics`
  - secret prefix: `prometheus/smartctl`
- `jellyfin`
  - public mTLS endpoint: `https://beast:9594/metrics`
  - local upstream: `http://127.0.0.1:19594/metrics`
  - secret prefix: `prometheus/jellyfin`

### `prox-srvarrvm`

- `sabnzbd`
  - public mTLS endpoint: `https://prox-srvarrvm:9387/metrics`
  - local upstream: `http://127.0.0.1:19387/metrics`
  - secret prefix: `prometheus/sabnzbd`

### `prox-orgvm`

- `vikunja`
  - public mTLS endpoint: `https://prox-orgvm:9345/metrics`
  - local upstream: `http://127.0.0.1:3456/api/v1/metrics`
  - secret prefix: `prometheus/vikunja`

## Prometheus Changes

`prox-fanavm` now scrapes these endpoints over `https` with client-cert auth.

Notable details:

- `node-mtls` is unchanged
- `smartctl`, `jellyfin`, `sabnzbd`, and `vikunja` now use endpoint metadata
  instead of exporter-internal ports
- remote blackbox probe sources can now mix:
  - local plain HTTP from `fana`
  - remote HTTPS+mTLS from other NixOS hosts

The relevant config is in:

- [nixos/fanavm/default.nix](../fanavm/default.nix)

## Grafana

Grafana now has a dedicated scrape-transport board:

- [nixos/fanavm/grafana/dashboards/scrape-health.json](../fanavm/grafana/dashboards/scrape-health.json)

It is meant to answer:

- is Prometheus reaching the mTLS-wrapped exporters/apps at all
- is the remote blackbox exporter transport healthy by probe source

This is separate from the service-specific dashboards that consume the scraped
metrics afterward.

## Secret Layout

The host templates now expect per-endpoint server certs:

- `frame`
  - `prometheus.blackbox.server_crt`
  - `prometheus.blackbox.server_key`
- `beast`
  - `prometheus.blackbox.server_crt`
  - `prometheus.blackbox.server_key`
  - `prometheus.smartctl.server_crt`
  - `prometheus.smartctl.server_key`
  - `prometheus.jellyfin.server_crt`
  - `prometheus.jellyfin.server_key`
- `prox-srvarrvm`
  - `prometheus.sabnzbd.server_crt`
  - `prometheus.sabnzbd.server_key`
- `prox-orgvm`
  - `prometheus.vikunja.server_crt`
  - `prometheus.vikunja.server_key`

## Certificate Issuance App

There is now a flake app to issue these certificates from `prox-pkivm` and
write them into the target host secret:

```bash
nix run .#issue-observability-cert -- --host frame --endpoint blackbox
nix run .#issue-observability-cert -- --host prox-srvarrvm --endpoint sabnzbd
nix run .#issue-observability-cert -- --host prox-orgvm --endpoint vikunja
```

If `--endpoint` is omitted, the app issues certs for every configured
`prometheusMtlsEndpoints` entry on that host.

The app:

- reads endpoint metadata from the NixOS config
- SSHes to `prox-pkivm`
- runs `step ca certificate` there with the bootstrap provisioner
- runs `sops-update` for the target host secret
- writes the issued cert/key into the configured secret prefix

Source:

- [pkgs/issue-observability-cert/main.py](../../pkgs/issue-observability-cert/main.py)

## Maintenance Window Constraint

`beast` implementation is present in the repo, but deployment is intentionally
deferred.

Anything that touches `beast` for this migration needs a separate maintenance
window, so rollout should start with:

- `frame`
- `prox-srvarrvm`
- `prox-orgvm`
- `prox-fanavm`

and leave `beast` for a later dedicated window.

## Pending Rollout

Implementation is done. What remains is rollout:

1. Issue certs for `frame`, `prox-srvarrvm`, and `prox-orgvm`
2. Deploy those hosts
3. Deploy `prox-fanavm`
4. Verify the new Grafana scrape-health board and Prometheus targets
5. Schedule a separate maintenance window for `beast`
6. Issue `beast` certs
7. Deploy `beast`

After that, the remaining non-mTLS Prometheus scrapes should only be the
explicit out-of-scope set from the top of this file.
