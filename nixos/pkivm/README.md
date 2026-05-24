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
    `radarr`, `sonarr`, and similar nginx-fronted LAN endpoints
- `nix run .#issue-observability-cert`
  - issue server certs for Prometheus mTLS scrape endpoints and client certs
    for mTLS consumers such as `jellyfin-upload-policy`
- `nix run .#deploy`
  - roll updated secrets and service config to the target host

## Common Flows

Internal HTTPS service cert:

```bash
nix run .#issue-internal-service-cert -- --host prox-fanavm --service grafana
nix run .#deploy -- --branch dhcp-unifi prox-fanavm
```

Prometheus mTLS endpoint cert:

```bash
nix run .#issue-observability-cert -- --host beast --endpoint jellyfin
nix run .#deploy -- --branch dhcp-unifi beast
```

Prometheus mTLS client cert:

```bash
nix run .#issue-observability-cert -- --host prox-srvarrvm --client jellyfin-upload-policy
nix run .#deploy -- --branch dhcp-unifi prox-srvarrvm
```

## Secret Handling

- Issuers update the target host secret file in `secrets/<host>.yaml`
- They run `sops-update` automatically before rewriting the encrypted file
- If a host does not have its secret file yet, bootstrap it first with the
  usual `sops` helpers

## Related Docs

- [unifi-sync.md](./unifi-sync.md)
- [http-to-https-rollout.md](./http-to-https-rollout.md)
