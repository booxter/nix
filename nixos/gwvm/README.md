# gw (NixOS VM)

This host is a minimal WireGuard gateway VM. Client peers are declared in
`nixos/gwvm/default.nix`, while the shared tunnel topology lives in
`lib/hosts.nix` under `site.wireguard.home` and `site.lan`.

## Client setup

Generate a client keypair locally:

```bash
umask 077
wg genkey | tee client.key | wg pubkey > client.pub
```

Pick a free address from `site.wireguard.home.cidr` in `lib/hosts.nix` and add
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
nix run .#prox-deploy -- gw prx1
# or, after the VM already exists
nix run .#deploy -- prox-gwvm
```

Read the server public key from the VM:

```bash
ssh prox-gwvm 'sudo wg pubkey < /var/lib/wireguard/wg0.key'
```

Create a client config locally:

```ini
[Interface]
PrivateKey = <contents of client.key>
Address = <peer-address>/32
DNS = <site.lan.gateway.address>

[Peer]
PublicKey = <server public key from prox-gwvm>
Endpoint = <site.wireguard.home.gateway.publicEndpoint>:<site.wireguard.home.gateway.listenPort>
AllowedIPs = <site.wireguard.home.cidr>, <site.lan.cidr>
PersistentKeepalive = 25
```

Optional QR code for mobile clients:

```bash
qrencode -t ansiutf8 < client.conf
```
