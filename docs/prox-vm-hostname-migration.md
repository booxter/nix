# Prox VM Hostname Migration

Temporary working note. Delete this after VM runtime hostnames, DNS aliases,
SSH principals, Prometheus labels, and the legacy `toProxVmName` helper are
cleaned up.

## Current State

The repo now uses short names for flake attrs, secrets, CI targets, and most
tools. Runtime identity still uses the old `prox-*vm` shape through inventory
helpers:

- `networking.hostName`
- `host.dnsName`
- SSH target hostnames
- SSH-ticket principals
- Prometheus scrape targets and `instance` labels
- DHCP reservation hostnames for most VMs

Current VM runtime names:

| spec name | current runtime DNS |
| --- | --- |
| `nv` | `prox-nvvm` |
| `cache` | `prox-cachevm` |
| `srvarr` | `prox-srvarrvm` |
| `fana` | `prox-fanavm` |
| `gw` | `prox-gwvm` |
| `org` | `prox-orgvm` |
| `pki` | `prox-pkivm` |
| `builder1` | `prox-builder1vm` |
| `builder2` | `prox-builder2vm` |
| `builder3` | `prox-builder3vm` |

Avahi is already short-name based for NixOS hosts, so names like
`srvarr.local` already exist separately from LAN DNS.

## Cross-Machine Consumers

`fana` is the main consumer of old VM runtime names. Prometheus scrapes use
`host.dnsName` for targets and labels, and hardcoded rules, tests, and
dashboards still mention `prox-srvarrvm`, `prox-pkivm`, `prox-builder2vm`,
`prox-orgvm`, and `prox-fanavm`.

`frame`, `mmini`, and `mair` use builder VM hostnames for distributed Nix
builders through `common/_mixins/personal-builders`.

`mair` currently enables generated SSH-ticket OpenSSH config, so `ssh <short>`
is backed by old `prox-*vm` hostnames there.

`pki` owns UniFi DHCP and DNS sync. DHCP-backed VMs get their old LAN
hostnames from inventory reservations. The current local DNS records add
service aliases, but not old/new host aliases for primary hostnames.

SSH-ticket servers accept only the current `username@host.dnsName` principal.
During migration they need to accept both old and new principals.

`beast`, `cache`, and `srvarr` mostly consume other machines by IP, service
alias, or short inventory config name. They are not the main source of old
runtime-name coupling.

## Staged Plan

1. Add explicit inventory identity helpers:
   - stable spec name: `spec.name`
   - runtime hostname: current OS `networking.hostName`
   - primary DNS name: current `host.dnsName`
   - legacy DNS names: old names kept during migration
   - all DNS names: primary plus legacy

2. Publish dual DNS before changing hostnames:
   - add `srvarr.home.arpa` and keep `prox-srvarrvm.home.arpa`
   - do the same for each DHCP-backed VM
   - keep DHCP reservation primary hostnames old at first

3. Make SSH-ticket dual-principal:
   - accept both `ihrachyshka@prox-srvarrvm` and `ihrachyshka@srvarr`
   - switch clients and tools after servers accept both

4. Decouple Prometheus labels from scrape target names:
   - use short spec names for `instance`
   - keep scrape targets on old DNS until dual DNS and certs are ready
   - update rules, tests, and dashboards once

5. Reissue certs with transitional SANs:
   - observability endpoint certs need old and new hostnames
   - the `pki` CA server cert needs old and new names too
   - this avoids TLS breakage while scrape targets move

6. Switch consumers to short DNS:
   - SSH-ticket client `HostName`
   - `update-machines` resolved SSH hostnames
   - Nix distributed builders
   - WireGuard gateway SSH host
   - Prometheus scrape targets

7. Flip runtime identity per VM:
   - change `networking.hostName`, `host.dnsName`, and DHCP reservation
     hostname
   - keep old DNS aliases and old SSH principals during rollout
   - start with low-blast hosts like `org` or `cache`
   - leave `pki`, `fana`, `srvarr`, and `gw` for later

8. Cleanup after rollout:
   - remove legacy DNS aliases
   - remove old SSH principals
   - remove transitional SAN generation
   - remove `toProxVmName`

## Notes

Builders and `nv` do not currently have DHCP reservations in inventory, so
dual LAN DNS for those requires either reservations or a separate naming path.

Module directory names like `nixos/srvarr` are repo shape, not runtime
identity. They already use the short inventory names, while runtime identity
still follows the migration plan above.
