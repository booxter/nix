# UCG Fiber Migration

This document tracks the migration away from `pi5` as the LAN DHCP/DNS host.
It is a working note, not a final design. Revise it as decisions harden.

## Goal

Replace the `pi5` network role with a UniFi Cloud Gateway Fiber (UCG Fiber):

- UCG Fiber becomes the authoritative LAN DHCP server
- UCG Fiber becomes the LAN DNS resolver for local clients
- `pi5` can either:
  - remain temporarily as the guest-network host
  - disappear completely
  - remain only as an external TFTP host for netboot

## Current Repo State

Current LAN inventory and addressing live in
[lib/inventory.nix](../lib/inventory.nix).

Important current values:

- LAN CIDR: `192.168.0.0/16`
- LAN domain: `home.arpa`
- upstream gateway: `192.168.0.1`
- `pi5` LAN address: `192.168.1.1`
- `pi5` guest-side address: `192.168.2.1`
- main DHCP pools:
  - `192.168.10.1 - 192.168.14.255`
  - `192.168.16.1 - 192.168.20.255`
- excluded subnets:
  - `192.168.15.0/24`
  - `192.168.50.0/24`
- guest DHCP pool:
  - `192.168.100.1 - 192.168.100.255`

Source:

- [lib/inventory.nix](../lib/inventory.nix)
- [nixos/pi5/default.nix](../nixos/pi5/default.nix)

`pi5` currently provides all of the following through `dnsmasq`:

- DHCP for the main LAN
- DHCP for the Pi-hosted guest network
- DNS for `home.arpa`
- local host aliases:
  - `dhcp -> 192.168.1.1`
  - `nix-cache -> prox-cachevm`
- split DNS for public service names to local `beast`
- PXE/TFTP for `netboot.xyz.efi`

It also currently acts as a NUT/UPS server through
[nixos/pi5/ups.nix](../nixos/pi5/ups.nix).

## Target State

Target assumptions for the first pass:

- UCG Fiber owns LAN routing, DHCP, and DNS
- UCG Fiber is the DNS server handed out to clients
- local hostnames should resolve via UCG Fiber
- public service names should either:
  - resolve through UCG Fiber local DNS overrides
  - or rely on hairpin NAT if that proves good enough
- guest WiFi must remain isolated from the trusted LAN
- `pi5` may remain temporarily as a guest-only network box if the WiFi layer
  cannot yet do a proper guest VLAN back to the UCG Fiber

## Transitional Option

The migration does not need to be all-or-nothing.

A reasonable intermediate state is:

- UCG Fiber owns the trusted LAN:
  - main DHCP
  - main DNS
  - main routing
- `pi5` remains only for guest access:
  - guest-side addressing
  - guest DHCP
  - any temporary guest WiFi role still tied to the Pi

This is useful if the current mesh bridge cannot yet present a guest SSID on a
separate VLAN to the UCG Fiber.

The important constraint in that model is that `pi5` must stop being the
authoritative DHCP/DNS host for the trusted LAN. It should survive only as an
explicitly temporary guest-network dependency.

## UniFi Capability Check

The UCG Fiber is a fit for the general direction, but not for a perfect
drop-in replacement of the current `dnsmasq` behavior.

### Confirmed Fits

As checked against official Ubiquiti docs on May 23, 2026:

- UniFi gateways support DHCP per network/VLAN
- UniFi gateways support DNS records and local hostnames
- UniFi gateways support conditional forwarding through `Forward Domain`
- UniFi gateways support DHCP options `66` and `67` for network boot
- UniFi supports hairpin NAT
- UniFi supports guest and isolated networks when the AP path carries the
  correct VLANs

### Known Gaps

- No official documentation was found for DHCP reservations keyed by DHCP
  option `61` / client identifier.
- No official documentation was found for automatic `dnsmasq`-style promotion
  of all DHCP lease hostnames into local DNS.
- Official UniFi docs describe a single DHCP start/stop range per virtual
  network. No official support was found for the current disjoint pool layout
  in one flat LAN.

Decision for this migration:

- do not attempt to preserve option `61` / client-id reservations
- convert all important reservations to MAC-based reservations or static IPs

## API Surface Comparison

UniFi now has an official documented Network API, but the older internal
controller API still appears broader for some host-management tasks.

### Official Network API

What is clearly documented in the official API:

- networks / VLANs
- WiFi broadcasts / SSID-to-network mapping
- firewall zones and firewall policies
- ACL rules
- DNS policies / DNS records

This makes the official API a good fit for:

- guest VLAN design
- guest SSID mapping
- guest isolation rules
- local DNS overrides for important names
- general network inventory and policy automation

What is not documented in the official API pages checked so far:

- fixed-IP reservation fields like `use_fixedip` and `fixed_ip`
- DHCP network fields like `dhcpd_start`, `dhcpd_stop`, `dhcpd_dns_1`,
  `dhcpd_dns_2`, and `domain_name`
- option `61` / client-id reservation support
- a documented API path for the UI feature that ties `Fixed IP Address` and
  `Local DNS Record` to a known client

The practical implication is that the official API looks good for:

- networks
- WiFi
- firewall
- ACLs
- DNS policies

but not yet for full replacement of the current `dnsmasq` host-assignment
behavior.

### Legacy / Internal Controller API

The legacy controller API appears to expose more of the low-level host and DHCP
model.

Concrete traces found in legacy client software:

- fixed-IP reservation methods using:
  - `PUT /api/s/{site}/rest/user/{client_id}`
  - payload fields `use_fixedip`, `network_id`, and `fixed_ip`
- raw network configuration objects with fields like:
  - `dhcpd_enabled`
  - `dhcpd_start`
  - `dhcpd_stop`
  - `dhcpd_dns_1`
  - `dhcpd_dns_2`
  - `domain_name`

This makes the legacy API the only path where there is current evidence for:

- automating fixed-IP reservations
- automating DHCP range/domain/DNS settings in a UniFi-shaped data model

However, even in the legacy ecosystem, no evidence was found for:

- DHCP option `61` / client-id reservation support
- multiple disjoint DHCP pools on one network object
- a clear API for the modern `Local DNS Record` feature

### Recommended Automation Posture

At the moment, the safest working assumption is:

- use the official API for:
  - networks / VLANs
  - WiFi broadcasts
  - guest isolation
  - DNS policies / DNS overrides
- use the legacy API only if we decide to automate:
  - fixed-IP reservations
  - DHCP network settings not exposed in the official docs
- assume option `61` reservations will still need redesign, not automation

This likely means any inventory-driven UniFi integration will either be:

- mostly official API plus a small amount of manual UI work
- or a hybrid model that uses official API where possible and legacy API only
  for the missing reservation / DHCP pieces

## Migration Risks

### 1. DHCP Reservation Model

Several existing reservations are keyed by client identifier today, not just
MAC address. Those will need to become MAC-based reservations or true static
IPs.

### 2. Local Hostname Resolution

Do not assume UniFi will automatically resolve every DHCP hostname the way
`dnsmasq` does today. Plan on creating explicit local hostnames or DNS records
for important systems.

### 3. Guest Network Isolation

The biggest non-gateway risk is the WiFi layer.

If the current mesh is only a plain bridge and cannot map a guest SSID to a
separate VLAN, then guest traffic will land on the same LAN as trusted clients
and the UCG Fiber cannot isolate it as a true guest network.

Guest isolation is only clean if the WiFi layer can do:

- `guest SSID -> guest VLAN`
- tagged uplink of that VLAN back to the UCG Fiber

If the mesh cannot do that in bridge mode, the likely options are:

- replace the WiFi layer with APs that support VLAN-tagged SSIDs
- keep `pi5` as the guest-network host for now
- accept no real guest network for now
- rely on AP-side client isolation only, if the mesh supports it

Client isolation is not a substitute for a separate guest VLAN.

### 4. TFTP / Netboot

If `pi5` goes away entirely, netboot goes away with it.

If netboot is still needed, keep a minimal TFTP server somewhere and have the
UCG Fiber advertise:

- option `66`: TFTP server
- option `67`: boot filename

### 5. UPS / NUT

Removing `pi5` also removes its UPS/NUT server role.

Decision for this migration:

- move the UPS/NUT server role to `nvws`

## Proposed DNS Model

First-pass assumption:

- UCG Fiber serves DNS directly to clients
- important local systems get explicit UniFi local hostnames or `A` records
- public service names get local overrides only if hairpin NAT is insufficient

Names currently worth preserving explicitly:

- `beast`
- `beast-ipmi`
- `nvws`
- `prx1-lab`
- `prx2-lab`
- `prx3-lab`
- `mair`
- `mlt`
- `mdx`
- `sw-lab`
- `prox-srvarrvm`
- `prox-gwvm`
- `prox-orgvm`
- `prox-pkivm`
- `nix-cache`
- `prox-cachevm`

Public service overrides currently served locally by `pi5`:

- `jf.ihar.dev`
- `js.ihar.dev`
- `mu.ihar.dev`
- `au.ihar.dev`
- `shelf.ihar.dev`
- `vi.ihar.dev`

## Reservation Inventory

Current reservations from [lib/inventory.nix](../lib/inventory.nix):

| Hostname | IP | Current match style | Migration note |
| --- | --- | --- | --- |
| `mdx` | `192.168.10.100` | MAC | should migrate cleanly |
| `mlt` | `192.168.11.2` | client-id | convert to MAC or static IP |
| `mair` | `192.168.11.3` | MAC and client-id | keep MAC reservation only |
| `sw-lab` | `192.168.15.1` | MAC | should migrate cleanly |
| `beast-ipmi` | `192.168.16.4` | MAC | should migrate cleanly |
| `nvws` | `192.168.15.100` | MAC | should migrate cleanly |
| `beast` | `192.168.16.3` | client-id | convert to MAC or static IP |
| `prx1-lab` | `192.168.15.10` | MAC | should migrate cleanly |
| `prx2-lab` | `192.168.15.11` | MAC | should migrate cleanly |
| `prx3-lab` | `192.168.15.12` | MAC | should migrate cleanly |
| `prox-srvarrvm` | `192.168.20.2` | client-id | convert to MAC or static IP |
| `prox-gwvm` | `192.168.20.3` | client-id | convert to MAC or static IP |
| `prox-orgvm` | `192.168.20.4` | client-id | convert to MAC or static IP |
| `prox-pkivm` | `192.168.20.5` | client-id | convert to MAC or static IP |

## Proposed Cutover Shape

### Phase 1: Decide the WiFi Story

Before touching DHCP/DNS:

- confirm whether the current mesh can map a guest SSID to a VLAN while in
  bridge mode
- if not, decide whether to:
  - replace the mesh/AP layer
  - keep `pi5` as the temporary guest-network host
  - drop the guest network
  - postpone the migration

### Phase 2: Normalize Reservations

- identify MAC addresses for the current client-id-based reservations
- decide which systems should instead use static IPs
- remove any expectation that UniFi will match reservations by client-id
- shrink the set of required reserved names to the hosts that matter

### Phase 3: Simplify the DHCP Layout

The current layout is optimized for `dnsmasq`, not obviously for UniFi.

Options:

- keep the existing `/16` and attempt a single UniFi-friendly dynamic range,
  with important hosts reserved outside that dynamic range
- or redesign the LAN into simpler VLAN-backed subnets

The first option is less ambitious and is the likely starting point.

### Phase 4: Recreate Critical DNS State

- create local DNS records / local hostnames for important hosts
- decide whether to add local overrides for the public services
- validate:
  - `home.arpa` resolution
  - public service access from inside the LAN
  - WireGuard clients that currently assume the LAN DNS server

### Phase 5: Move PXE/TFTP or Drop It

- if netboot still matters, keep a minimal TFTP server outside `dnsmasq`
- otherwise remove PXE/TFTP from the design completely

### Phase 6: Remove `pi5` Role from the Repo

Once the network cutover is complete:

- remove or repurpose `nixos/pi5/default.nix`
- remove `pi5`-specific DNS observability from `fana`
- update LAN DNS assumptions in:
  - [lib/fleet.nix](../lib/fleet.nix)
  - [darwin/mair/default.nix](../darwin/mair/default.nix)
  - [nixos/fanavm/default.nix](../nixos/fanavm/default.nix)
- move the `pi5` UPS/NUT role and consumers to `nvws`

If `pi5` remains for guest networking during the transition, this final phase
only starts after that guest dependency is removed.

## Open Questions

- Should the final LAN stay a flat `192.168.0.0/16`, or should it be broken
  into smaller VLAN-backed subnets?
- Is the current guest network still required?
- If the guest network stays, should `pi5` keep it temporarily while the main
  LAN moves to the UCG Fiber?
- Does the current mesh support tagged guest SSIDs while bridged?
- Which current client-id reservations still need MAC discovery before cutover?
- Do we want internal DNS overrides for public service names, or should we rely
  on UniFi hairpin NAT?
- Is netboot still worth keeping?

## Vendor References

These are the main vendor docs used for the initial compatibility check:

- UniFi DHCP Server:
  https://help.ui.com/hc/en-us/articles/360012097513-UniFi-DHCP-Server
- UniFi DNS Records and Local Hostnames:
  https://help.ui.com/hc/en-us/articles/15179064940439-UniFi-DNS-Records-and-Local-Hostnames
- Hairpin NAT in UniFi:
  https://help.ui.com/hc/en-us/articles/30202160464023-Hairpin-NAT-in-UniFi
- Creating Virtual Networks (VLANs):
  https://help.ui.com/hc/en-us/articles/9761080275607-Creating-Virtual-Networks-VLANs
- Implementing Network and Client Isolation in UniFi:
  https://help.ui.com/hc/en-us/articles/18965560820247-Implementing-Network-and-Client-Isolation-in-UniFi
- UniFi Hotspots and Captive Portals:
  https://help.ui.com/hc/en-us/articles/115000166827-UniFi-Hotspots-and-Captive-Portals
- UCG Fiber tech specs:
  https://techspecs.ui.com/unifi/cloud-gateways/ucg-fiber

Useful reference points for the API comparison:

- Official UniFi API overview:
  https://help.ui.com/hc/en-us/articles/30076656117655-Getting-Started-with-the-Official-UniFi-API
- Official UniFi Network API:
  https://developer.ui.com/network/v10.3.58/gettingstarted
- Official Networks endpoint overview:
  https://developer.ui.com/network/v10.3.58/getnetworksoverviewpage
- Official DNS Policies endpoint overview:
  https://developer.ui.com/network/v10.3.58/getdnspolicypage
- Official Firewall Policies endpoint overview:
  https://developer.ui.com/network/v10.3.58/getfirewallpolicies
- Official ACL Rules endpoint overview:
  https://developer.ui.com/network/v10.3.58/createaclrule
- Legacy PHP client showing fixed-IP reservation support:
  https://github.com/Art-of-WiFi/UniFi-API-client
- Legacy Node client showing fixed-IP reservation support:
  https://github.com/jens-maus/node-unifi
- Legacy Python client showing fixed-IP reservation and `networkconf` fields:
  https://github.com/tnware/unifi-controller-api
