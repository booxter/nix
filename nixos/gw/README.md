# gw (NixOS VM)

This host is a minimal WireGuard gateway VM. The server and client registry
lives in `facts/site/facts.nix` under `wireguard.home`. Assigning `gw` as the
gateway host makes the shared WireGuard server module configure its interface,
firewall, NAT, DDNS, traffic shaping, and exporter.

## Client setup

Generate a client keypair locally:

```bash
umask 077
wg genkey | tee client.key | wg pubkey > client.pub
```

Pick a free address from `wireguard.home.cidr` in `facts/site/facts.nix` and
add the peer to `wireguard.home.peers`:

```nix
mair = {
  host = "mair"; # Only for a managed fleet client.
  publicKey = "<contents of client.pub>";
  address = "<peer-address>/32";
};
```

For a managed fleet client, `host` registers the machine with the shared
WireGuard client module. The module provisions its SOPS private-key secret and
`wg-quick` interface from these facts. Omit `host` for an externally managed
peer such as a phone or travel router.

Deploy or redeploy the VM:

```bash
nix run .#prox-deploy -- gw prx1-lab
# or, after the VM already exists
nix run .#deploy -- gw
```

Generate a client config locally from the tracked topology:

```bash
nix run .#wg-home-client-config -- \
  --peer <facts-peer-name> \
  --private-key-file ./client.key \
  --fetch-server-public-key \
  --output ./client.conf
```

For a peer that is not modeled in `site.wireguard.home.peers`, use
`--address <peer-address>/32` instead of `--peer`.

Generated client configs use the LAN DNS server plus the `home.arpa` search
domain, so short hostnames resolve over the VPN the same way they do on the LAN.
They also set `PersistentKeepalive = 25`, which keeps peer handshakes fresh
enough for the status exporter to identify connected peers.

Optional QR code for mobile clients:

```bash
qrencode -t ansiutf8 < client.conf
```

## Peer status exporter

`gw` exposes facts-backed WireGuard peer status through an mTLS-protected
nginx endpoint for the DNS automation on `pki`:

- service: `prometheus-wireguard-exporter.service`
- local exporter listener: `127.0.0.1:9587`
- mTLS listener: `gw.home.arpa:9586`
- Prometheus endpoint: `/metrics`
- server certificate secret prefix: `prometheus/wg-home`

The DNS sync on `pki` marks a peer connected when
`wireguard_latest_handshake_seconds` is no older than 180 seconds.
