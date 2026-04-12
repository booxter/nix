# gw (NixOS VM)

This host is a minimal WireGuard gateway VM. Client peers are declared in
`nixos/gwvm/default.nix`.

## Client setup

Generate a client keypair locally:

```bash
umask 077
wg genkey | tee client.key | wg pubkey > client.pub
```

Pick a free address in `10.83.0.0/24` and add the peer to the `vpnPeers` list
in `nixos/gwvm/default.nix`:

```nix
{
  name = "iphone";
  publicKey = "<contents of client.pub>";
  address = "10.83.0.10";
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
Address = 10.83.0.10/32
DNS = 192.168.1.1

[Peer]
PublicKey = <server public key from prox-gwvm>
Endpoint = wg.ihar.dev:51820
AllowedIPs = 10.83.0.0/24, 192.168.0.0/16
PersistentKeepalive = 25
```

Optional QR code for mobile clients:

```bash
qrencode -t ansiutf8 < client.conf
```
