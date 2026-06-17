# `prox-pkivm`

`prox-pkivm` is the home fleet control-plane VM for internal PKI and UniFi
state sync. It runs `step-ca`, keeps the CA state in `/var/lib/step-ca`, and
is the machine from which we issue internal HTTPS and Prometheus mTLS leaf
certificates into host `sops` secrets. It also runs the `unifi-sync` timer so
trusted-LAN DHCP and split DNS stay converged with inventory.

## PKI Use

- CA service: `step-ca` on TCP `8443`
- CA state: `/var/lib/step-ca`
- Root trust anchor distributed from:
  - [common/_mixins/internal-pki/home-internal-pki-root-ca.crt](../../common/_mixins/internal-pki/home-internal-pki-root-ca.crt)
- UniFi sync service docs:
  - [unifi-sync.md](./unifi-sync.md)

## PKI Apps

- `nix run .#issue-internal-service-cert`
  - issue server certs for internal HTTPS services like `glance`, `grafana`,
    `radarr`, `sonarr`, and similar nginx-fronted LAN endpoints, plus local
    cert/key files for manual UniFi Console import
- `nix run .#issue-observability-cert`
  - issue server certs for Prometheus mTLS scrape endpoints and client certs
    for mTLS consumers such as `jellyfin-upload-policy`
- `nix run .#pki-rotation`
  - inspect managed PKI cert state, export Prometheus metrics, and run the
    PR-based rotation controller flow
- `nix run .#deploy`
  - roll updated secrets and service config to the target host

## Common Flows

Internal HTTPS service cert:

```bash
nix run .#issue-internal-service-cert -- --host fana --service grafana
nix run .#deploy -- --branch dhcp-unifi fana
```

Prometheus mTLS endpoint cert:

```bash
nix run .#issue-observability-cert -- --host beast --endpoint jellyfin
nix run .#deploy -- --branch dhcp-unifi beast
```

Prometheus mTLS client cert:

```bash
nix run .#issue-observability-cert -- --host srvarr --client jellyfin-upload-policy
nix run .#deploy -- --branch dhcp-unifi srvarr
```

UniFi Console certificate for manual import:

```bash
nix run .#issue-internal-service-cert -- --unifi --output-dir /private/tmp/unifi-cert
```

This writes `unifi.home.arpa.crt`, `unifi.home.arpa.key`, and
`unifi.home.arpa.pem` into the output directory using the CA's configured leaf
lifetime, currently 180 days. The `.pem` file is the bundled certificate plus
private key next to the standalone private key file.

PKI status inventory:

```bash
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" \
  nix run .#pki-rotation -- scan
```

PKI rotation dry-run:

```bash
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" \
  nix run .#pki-rotation -- rotate --dry-run
```

## Secret Handling

- Issuers update the target host secret file in `secrets/<host>.yaml`
- They run `sops-update` automatically before rewriting the encrypted file
- If a host does not have its secret file yet, bootstrap it first with the
  usual `sops` helpers

## Related Docs

- [unifi-sync.md](./unifi-sync.md)
- [http-to-https-rollout.md](./http-to-https-rollout.md)
- [../../docs/pki-rotation-plan.md](../../docs/pki-rotation-plan.md)
