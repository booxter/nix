# UCG Fiber Migration

## Goal

Move trusted-LAN DHCP and DNS from `pi5` to the UniFi Cloud Gateway Fiber at
`192.168.0.1`.

Keep `pi5` only for roles that still need it during the transition:

- guest network, if the WiFi layer cannot do a proper guest VLAN yet
- TFTP / netboot, if it is still needed
- UPS / NUT, until that role moves to `nvws`

## Current Decisions

- LAN DNS/DHCP endpoint in the repo: `192.168.0.1`
- LAN domain: `home.arpa`
- Main DHCP range: `192.168.10.1 - 192.168.14.255`
- Keep the main range below `192.168.15.0/24` because nixarr still assumes
  that subnet for its WireGuard-facing proxy
- Guest DHCP range on `pi5`: `192.168.100.1 - 192.168.100.255`
- Reservations are MAC-based only; do not preserve DHCP option `61` matching
- UPS / NUT target host: `nvws`
- Trusted-LAN DHCP/DNS is still actually running on `pi5` until cutover
- `pi5` still has:
  - LAN address `192.168.1.1`
  - guest-side address `192.168.2.1`

## Checklist

### Done In Repo

- [x] Point the repo-wide LAN DNS/DHCP endpoint to `192.168.0.1`
- [x] Convert DHCP reservations from client-id matching to MAC-based matching
- [x] Simplify the main DHCP pool to one UniFi-friendly range
- [x] Build `nix run .#unifi-sync`
- [x] Sync through that app:
  - fixed reservations
  - `Local DNS Record`
  - DHCP range
  - DHCP `domain-name`
  - DHCP `domain-search` via option `119`
  - inventory-driven split-DNS records through UniFi DNS policies
- [x] Move `pi5` LAN and guest addresses into the `pi5` host record
- [x] Remove dead DHCP exclusion support from the repo
- [x] Move split-DNS aliases into host inventory and derive rendered DNS records

### Apply On UCG Fiber

- [ ] Create or rotate a UniFi API key
- [ ] Run the sync app against the gateway:

```bash
export UNIFI_BASE_URL='https://192.168.0.1'
export UNIFI_API_KEY='...'
export UNIFI_SITE='default'

nix run .#unifi-sync -- --debug
```

- [ ] Verify in UniFi that the trusted LAN now has:
  - fixed IP reservations for MAC-backed hosts
  - `Local DNS Record` set for those hosts
  - DHCP range `192.168.10.1 - 192.168.14.255`
  - DHCP domain name `home.arpa`
  - DHCP domain search `home.arpa`
  - DNS policies for:
    - `pi5.home.arpa`
    - `nix-cache.home.arpa -> prox-cachevm.home.arpa`
    - `jf.ihar.dev`
    - `js.ihar.dev`
    - `mu.ihar.dev`
    - `au.ihar.dev`
    - `shelf.ihar.dev`
    - `vi.ihar.dev`
- [ ] Verify that the gateway itself is the DNS server handed out to trusted-LAN
  clients

### Cut Over The Trusted LAN

- [ ] Disable main-LAN DHCP on `pi5`
- [ ] Stop using `pi5` as the trusted-LAN DNS server
- [ ] Renew leases on a small set of clients and verify:
  - gateway/DNS is `192.168.0.1`
  - local hostnames resolve
  - `nix-cache` resolves
  - internal access to public services works as expected
- [ ] Verify WireGuard client configs still pick up `192.168.0.1`
- [ ] Verify `scripts/update-machines.sh` can still resolve hosts through the
  gateway DNS

### Clean Up Remaining `pi5` Roles

- [ ] Decide whether the guest network stays on `pi5` temporarily or moves to a
  real guest VLAN on the UCG Fiber
- [ ] Move UPS / NUT from `pi5` to `nvws`
- [ ] Keep `pi5` only as a TFTP host if netboot is still needed
- [x] Remove `pi5` `dnsmasq`-specific observability from `fana`
- [ ] Remove or repurpose the remaining `pi5` network role after guest / TFTP /
  UPS dependencies are gone

## Risks / Open Questions

- UniFi should not be assumed to auto-register every DHCP hostname the way
  `dnsmasq` does. Important names must be made explicit.
- Guest isolation still depends on the WiFi layer being able to carry a guest
  VLAN. If the current mesh cannot do that while bridged, `pi5` stays in the
  picture or the guest network goes away.
- Internal access to the public `*.ihar.dev` services still needs a choice:
  local DNS overrides or hairpin NAT. The inventory and sync app are now set up
  for local overrides.
- `nix-cache.home.arpa` is rendered as a CNAME to `prox-cachevm.home.arpa`, so
  the target host name still needs to resolve on the gateway side.
- TFTP / netboot may not be worth preserving.
