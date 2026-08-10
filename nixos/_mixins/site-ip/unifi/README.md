# UniFi Sync Service

## Goal

`unifi-sync` keeps UniFi DHCP, local DNS, and facts-backed routing state in
sync with this repository. It lets the Nix facts remain the source of truth
while UniFi continues to serve the network-facing DHCP and DNS behavior.

The service is intentionally narrow: it reconciles declarative fleet data into
UniFi and avoids carrying hand-maintained network values in operational notes.
Exact addresses, domains, routes, and option definitions belong in facts and
the generated service environment.

## Architecture

A host selecting the `unifi` IP-controller flavor runs `unifi-sync` as a
systemd oneshot with a timer. The service uses a UniFi API key from
sops-managed secrets and calls the UniFi Network API to converge the configured
site.

The data path is:

1. Fleet facts are defined in [facts/default.nix](../../../../facts/default.nix).
2. [environment.nix](./environment.nix) renders those facts into
   the environment consumed by the service.
3. [service.nix](./service.nix) defines the service and timer, while the UniFi
   controller module supplies its fleet data and secret.
4. [cli.py](./pkgs/unifi-sync/src/unifi_sync/cli.py) reads the environment,
   compares it with UniFi state, and applies only the required changes.

## Managed State

The sync covers the UniFi-owned parts of trusted-LAN configuration:

- declared DHCP reservations for managed and unmanaged site hosts
- local DNS records and split DNS records
- DHCP network settings, including custom option definitions and values
- facts-backed static routes
- network boot settings

Classless static route DHCP data is calculated from structured route facts.
The repository should not store manually encoded DHCP payloads as configuration.

## WireGuard DNS

WireGuard peer DNS overrides are handled by `wg-home-dns-sync`, a separate
systemd service on the same host. It observes WireGuard exporter metrics over
mTLS, derives which peer-specific DNS overrides should exist, and applies that
DNS subset through the shared in-process UniFi client and reconciler.

Keeping this logic separate lets normal facts sync run on its timer while
WireGuard DNS can react on a shorter polling loop.

## Operating Notes

Treat the Nix facts and generated environment as the source of truth. If a
managed UniFi object is changed or deleted in the UniFi UI, the next sync should
recreate or restore it from repository state.

For dry runs, inspect the controller service command and append `--dry-run`
before a deployment or live run. Add tests for encoding or payload behavior in
[test_cli.py](./pkgs/unifi-sync/tests/test_cli.py) rather than documenting sample
encoded values here.

TLS certificate verification is enabled by default. Use `--insecure-tls` only
for temporary troubleshooting against an untrusted local console certificate.
