# UniFi Sync Service

## Goal

`unifi-sync` keeps UniFi DHCP, local DNS, and inventory-backed routing state in
sync with this repository. It lets the Nix inventory remain the source of truth
while UniFi continues to serve the network-facing DHCP and DNS behavior.

The service is intentionally narrow: it reconciles declarative fleet data into
UniFi and avoids carrying hand-maintained network values in operational notes.
Exact addresses, domains, routes, and option definitions belong in inventory and
the generated service environment.

## Architecture

`prox-pkivm` runs `unifi-sync` as a systemd oneshot with a timer. The service
uses a UniFi API key from sops-managed secrets and calls the UniFi Network API
to converge the configured site.

The data path is:

1. Fleet facts are defined in [inventory.nix](../../lib/inventory.nix).
2. [unifi-sync-env.nix](../../lib/unifi-sync-env.nix) renders those facts into
   the environment consumed by the service.
3. [unifi-sync.nix](./unifi-sync.nix) wires the package, secrets, systemd unit,
   and timer.
4. [main.py](../../pkgs/unifi-sync/main.py) reads the environment, compares it
   with UniFi state, and applies only the required changes.

## Managed State

The sync covers the UniFi-owned parts of trusted-LAN configuration:

- fixed DHCP reservations for inventory hosts
- local DNS records and split DNS records
- DHCP network settings, including custom option definitions and values
- inventory-backed static routes
- network boot settings

Classless static route DHCP data is calculated from structured route inventory.
The repository should not store manually encoded DHCP payloads as configuration.

## WireGuard DNS

WireGuard peer DNS overrides are handled by `wg-home-dns-sync`, a separate
systemd service on the same host. It observes WireGuard exporter metrics over
mTLS, derives which peer-specific DNS overrides should exist, and invokes
`unifi-sync` to apply that DNS subset.

Keeping this logic separate lets normal inventory sync run on its timer while
WireGuard DNS can react on a shorter polling loop.

## Operating Notes

Treat the Nix inventory and generated environment as the source of truth. If a
managed UniFi object is changed or deleted in the UniFi UI, the next sync should
recreate or restore it from repository state.

Use `unifi-sync --dry-run` when checking what the service would change before a
deployment or live run. Add tests for encoding or payload behavior in
[test_unifi_sync.py](../../tests/test_unifi_sync.py) rather than documenting
sample encoded values here.

TLS certificate verification is enabled by default. Use `--insecure-tls` only
for temporary troubleshooting against an untrusted local console certificate.
