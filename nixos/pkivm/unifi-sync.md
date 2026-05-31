# UniFi Sync Service

## Scope

Trusted-LAN DHCP and DNS run on the UniFi Cloud Gateway Fiber at
`192.168.0.1`.

This document describes the current `unifi-sync` service on `prox-pkivm` that
keeps the UCG configuration converged with inventory.

Guest networking and UPS / NUT are out of scope here.

## Current Service

`prox-pkivm` runs `unifi-sync` as:

- `systemd` oneshot service: `unifi-sync.service`
- `systemd` timer: `unifi-sync.timer`

Current timer behavior:

- `OnBootSec=10m`
- `OnUnitActiveSec=1h`
- `RandomizedDelaySec=10m`
- `Persistent=true`

Secret wiring:

- API key comes from `secrets/prox-pkivm.yaml`
- `sops` key path: `unifi/api_key`
- runtime env file: `sops.templates."unifi-sync.env"`

Service source:

- [unifi-sync.nix](./unifi-sync.nix)
- [lib/unifi-sync-env.nix](../../lib/unifi-sync-env.nix)
- [pkgs/unifi-sync/main.py](../../pkgs/unifi-sync/main.py)

## UCG State Managed By The Service

- Fixed IP reservations for MAC-backed hosts
- `Local DNS Record` for those hosts
- DHCP range:
  - `192.168.10.1 - 192.168.14.255`
- DHCP domain name:
  - `home.arpa`
- DHCP domain search via option `119`
  - UniFi stores the value as plain text `home.arpa`
  - UniFi emits the correct RFC3397 encoding on the wire
- DHCP network-boot settings:
  - option `66` / next-server -> `192.168.15.10`
  - option `67` / boot file -> `netboot.xyz.efi`
- Split DNS records:
  - `nix-cache.home.arpa -> 192.168.20.7`
  - `jf.ihar.dev -> 192.168.16.3`
  - `js.ihar.dev -> 192.168.16.3`
  - `mu.ihar.dev -> 192.168.16.3`
  - `au.ihar.dev -> 192.168.16.3`
  - `shelf.ihar.dev -> 192.168.16.3`
  - `vi.ihar.dev -> 192.168.16.3`

## Trusted-LAN Runtime State

- Trusted-LAN clients renew from `192.168.0.1`
- Trusted-LAN clients get DNS `192.168.0.1`
- Repo-wide LAN DNS/DHCP endpoint is `192.168.0.1`
- LAN domain is `home.arpa`
- Reservations are MAC-based only
- `prx1-lab` serves standalone TFTP / netboot on `192.168.15.10`

## Validation We Proved

- Local hostnames resolve through gateway DNS
- `nix-cache.home.arpa` resolves directly to the cache VM
- Public split-DNS overrides resolve internally to `beast`
- Raw DHCP capture confirmed:
  - option `15` / domain-name
  - option `66` / next-server
  - option `67` / boot file
- Non-invasive DHCP probing confirmed option `119` is emitted correctly when
  UniFi stores the value as plain text `home.arpa`
- `unifi-sync.service` on `prox-pkivm` runs successfully and converges to
  `changed_count: 0`

## Operational Notes

- Treat `unifi-sync` as the source of truth for trusted-LAN reservations, DHCP
  settings, and split DNS
- If UniFi custom DHCP option `119` is deleted in the UI, `unifi-sync` will
  recreate the DHCP option definition and repopulate its value
- For UniFi option `119`, the stored value should be plain text `home.arpa`,
  not a hex string

## Optional Follow-Ups

- Extend mTLS to non-node Prometheus scrapers if desired
- Rotate UniFi API keys when needed
