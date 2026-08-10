# gw (NixOS VM)

This host is a minimal WireGuard gateway VM. Its native
`host.wireguard.server` declaration makes the shared server module configure
the interface, firewall, NAT, DDNS, traffic shaping, and exporter. Managed
clients register independently through `host.wireguard.client`; the fleet
model joins both declarations by network name.

## Client setup

Generate a client keypair locally:

```bash
umask 077
wg genkey | tee client.key | wg pubkey > client.pub
```

For a managed host, declare the client in that host's configuration:

```nix
host.wireguard.client = {
  enable = true;
  network = "home";
  publicKey = "<contents of client.pub>";
  address = "<peer-address>";
  privateKeySecret = "wireguard/gw/privateKey";
};
```

The shared client module provisions its SOPS private-key secret and `wg-quick`
interface from this declaration and the matching server policy. Add a phone,
travel router, or other unmanaged peer under
`host.wireguard.server.externalPeers` on `gw` instead.

Deploy or redeploy the VM:

```bash
nix run .#prox-deploy -- gw prx1-lab
# or, after the VM already exists
nix run .#deploy -- gw
```

Generate a client config locally from the tracked topology:

```bash
nix run .#wg-home-client-config -- \
  --peer <peer-name> \
  --private-key-file ./client.key \
  --fetch-server-public-key \
  --output ./client.conf
```

For a peer that is not modeled in the native topology, use
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

`gw` exposes option-backed WireGuard peer status through an mTLS-protected
nginx endpoint for the DNS automation on `pki`:

- service: `prometheus-wireguard-exporter.service`
- local exporter listener: `127.0.0.1:9587`
- mTLS listener: `gw.home.arpa:9586`
- Prometheus endpoint: `/metrics`
- server certificate secret prefix: `prometheus/wg-home`

The DNS sync on `pki` marks a peer connected when
`wireguard_latest_handshake_seconds` is no older than 180 seconds.
