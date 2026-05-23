# UCG Fiber Migration

## Goal

Move trusted-LAN DHCP and DNS from `pi5` to the UniFi Cloud Gateway Fiber at
`192.168.0.1`.

Guest-network and UPS / NUT migration are out of scope for this document.

## Current State

- Trusted-LAN DHCP and DNS are live on the UCG at `192.168.0.1`
- Repo-wide LAN DNS/DHCP endpoint is `192.168.0.1`
- LAN domain is `home.arpa`
- Main DHCP range is `192.168.10.1 - 192.168.14.255`
- The main range stays below `192.168.15.0/24` because nixarr still assumes
  that subnet for its WireGuard-facing proxy
- Reservations are MAC-based only
- `pi5` still has:
  - LAN address `192.168.1.1`
  - guest address `192.168.2.1`
- `pi5` now serves:
  - guest-only `dnsmasq` on `wlan0`
  - standalone TFTP / netboot on `192.168.1.1`
- `unifi-sync` runs on `prox-pkivm` as a systemd timer and keeps UniFi in sync

## What UniFi Is Managing

- Fixed IP reservations for MAC-backed hosts
- `Local DNS Record` for those hosts
- DHCP `domain-name`:
  - `home.arpa`
- DHCP `domain-search` via option `119`
  - UniFi stores this as plain text `home.arpa`
  - UniFi then emits the correct RFC3397 wire encoding
- DHCP network-boot options:
  - option `66` / next-server -> `192.168.1.1`
  - option `67` / boot file -> `netboot.xyz.efi`
- Split DNS records:
  - `pi5.home.arpa -> 192.168.1.1`
  - `nix-cache.home.arpa -> 192.168.20.7`
  - `jf.ihar.dev -> 192.168.16.3`
  - `js.ihar.dev -> 192.168.16.3`
  - `mu.ihar.dev -> 192.168.16.3`
  - `au.ihar.dev -> 192.168.16.3`
  - `shelf.ihar.dev -> 192.168.16.3`
  - `vi.ihar.dev -> 192.168.16.3`

## Validation That Was Completed

- Trusted-LAN clients renew from `192.168.0.1`
- Trusted-LAN clients get DNS `192.168.0.1`
- Local hostnames resolve through gateway DNS
- `nix-cache.home.arpa` resolves directly to the cache VM
- Public split-DNS overrides resolve internally to `beast`
- `pi5` no longer serves trusted-LAN DHCP
- Raw DHCP capture confirmed:
  - option `15` / domain-name
  - option `66` / next-server
  - option `67` / boot file
- A non-invasive DHCP probe confirmed option `119` is emitted correctly when
  UniFi stores the value as plain text `home.arpa`

## Operational Notes

- `unifi-sync` should be treated as the source of truth for trusted-LAN
  reservations, DHCP settings, and split DNS
- If UniFi custom DHCP option `119` is deleted in the UI, `unifi-sync` will
  recreate the DHCP option definition and repopulate its value
- For UniFi option `119`, the stored value should be plain text `home.arpa`,
  not a hex string

## Optional Follow-Ups

- Keep or remove TFTP / netboot on `pi5`
- Extend mTLS to non-node Prometheus scrapers if desired
- Rotate UniFi API keys when needed
