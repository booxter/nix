# gw (NixOS VM)

This host is a minimal WireGuard gateway VM. Client peers are declared in
`nixos/gwvm/default.nix`, while the shared tunnel topology lives in
`lib/inventory.nix` under `site.wireguard.home` and `site.lan`.

## Client setup

Generate a client keypair locally:

```bash
umask 077
wg genkey | tee client.key | wg pubkey > client.pub
```

Pick a free address from `site.wireguard.home.cidr` in `lib/inventory.nix` and add
the peer to the `vpnPeers` list in `nixos/gwvm/default.nix`:

```nix
{
  name = "iphone";
  publicKey = "<contents of client.pub>";
  address = "<peer-address>/32";
}
```

Deploy or redeploy the VM:

```bash
nix run .#prox-deploy -- gw prx1-lab
# or, after the VM already exists
nix run .#deploy -- gw
```

Generate a client config locally from the tracked topology:

```bash
nix run .#wg-home-client-config -- \
  --peer <inventory-peer-name> \
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

`gw` exposes inventory-backed WireGuard peer status for the DNS automation on
`pki`:

- service: `wg-home-exporter.service`
- listener: `192.168.20.3:9586`
- JSON endpoint: `/peers.json`
- Prometheus endpoint: `/metrics`

The exporter marks a peer connected when its latest WireGuard handshake is no
older than 180 seconds.
