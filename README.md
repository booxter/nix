# Nix configs

This repo provides flake apps and scripts as the primary interfaces. The
`Makefile` is a convenience wrapper for a few host build commands.

## Build and Deploy

```sh
# Host builds
make nixos WHAT=frame
make darwin WHAT=mair

# Local VMs
nix run .#vm -- --help
nix run .#vm -- builder1
nix run .#vm -- --gui frame
nix run .#vm -- srvarr
nix run .#vm -- fana
nix run .#vm -- gw
nix run .#vm -- org
nix run .#vm -- beast

# Config diff between two Git revisions
nix run .#diff -- frame <old-rev> <new-rev>
nix run .#diff -- mair <old-rev> <new-rev>

# Proxmox VM deploy
nix run .#prox-deploy -- srvarr prx1-lab
nix run .#prox-deploy -- fana prx1-lab
nix run .#prox-deploy -- gw prx1-lab
nix run .#prox-deploy -- org prx1-lab

# Disk helpers
nix run .#deploy -- --disko frame /dev/sdX
```

Local VM and disk provisioning commands resolve the enclosing Git checkout at
runtime and must be run from inside one.

## Fleet updates

Update multiple machines over SSH with `nix run .#deploy` (defaults to
`--all`):

```sh
# Update all personal machines (default)
nix run .#deploy -- -A

# Stage a NixOS config for reboot instead of switching immediately
nix run .#deploy -- --branch ci/flake-update --boot srvarr

# Update all work machines
nix run .#deploy -- -A --work

# Update a subset interactively
nix run .#deploy -- -A --select

# Dry run (print selected hosts only)
nix run .#deploy -- -A --dry-run
```

Deployments to different hosts can run at the same time. If a selected host is
already being deployed from this machine, wait for that deployment to finish and
retry.

Remote deployments copy the committed source to the target, where Nix builds the
deployment helper and system using the target's configured caches and builders.
The controller does not build or publish the remote system closure. Signature
checks remain enabled when copying the content-addressed source.

## Secrets

See [SOPS tools](apps/sops/README.md) for secret management commands and
Touch ID/YubiKey authentication over SSH.

## Tests

Run Bats checks:

```sh
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build ".#checks.${system}.bats" --no-link
```

Run full flake checks (same entrypoint used in CI):

```sh
nix flake check -L --show-trace
```

## CI

CI matrix selection rules and skip behavior are documented in
[.github/README.md](.github/README.md).

## Machines

All VMs run on Proxmox hosts. Use `prox-deploy` (a wrapper around `nixmoxer`)
for installation and `deploy` for subsequent updates.

Before installing a guest, store its unencrypted Ed25519 SSH host private key
in `pass` at `host/<guest>/ssh_host_ed25519_key`. Its public key must match
`nixos/<guest>/ssh_host_ed25519_key.pub`; prepare the host's SOPS recipients,
passwords, and builder credentials before installation. Keep the private key
outside the checkout and store only the key itself in the password-store entry.

`prox-deploy` validates that identity before creating a VM. It then delivers
the key over SSH to the Proxmox node and through the guest agent to the installer.
The installer waits for the validated identity before formatting, places it in
the installed system using disko's post-mount hook, and continues the existing
offline installation. The command waits for the installed host's SSH access and
SOPS decryption to succeed. On nodes that require a sudo password, deploy the
updated node configuration first: it grants the operator passwordless sudo for
the two required guest-agent commands. Access is checked before VM creation.
Normal SSH host-key verification applies to both the node and the guest.

### Infra (DHCP, Proxmox)

| Machine | Type | Purpose | Config | Includes |
| --- | --- | --- | --- | --- |
| `beast` | NixOS (x86_64-linux) | NAS storage + Jellyfin/Jellarr server. | [nixos/beast/default.nix](nixos/beast/default.nix) | [common](common), [nixos](nixos) |
| `nvws` | Proxmox host | Work Proxmox node configuration. Single node. Also serves as a remote x86_64-linux builder for work machines. | [nixos/nvws/default.nix](nixos/nvws/default.nix) | [common](common), [nixos](nixos) |
| `prx1-lab` | Proxmox host | Lab Proxmox node (cluster leader) and TFTP/netboot host. | [nixos/prx1-lab/default.nix](nixos/prx1-lab/default.nix) | [common](common), [nixos](nixos) |
| `prx2-lab` | Proxmox host | Lab Proxmox node (cluster member). | [nixos/prx2-lab/default.nix](nixos/prx2-lab/default.nix) | [common](common), [nixos](nixos) |
| `prx3-lab` | Proxmox host | Lab Proxmox node (cluster member). | [nixos/prx3-lab/default.nix](nixos/prx3-lab/default.nix) | [common](common), [nixos](nixos) |

### Nix infra

| Machine | Type | Purpose | Config | Includes |
| --- | --- | --- | --- | --- |
| `builder1` | CI VM | Primary builder VM for CI and heavy Nix builds. | [nixos/default.nix](nixos/default.nix) | [common](common), [nixos](nixos) |
| `builder2` | CI VM | Additional builder VM (same profile as `builder1`). | [nixos/default.nix](nixos/default.nix) | [common](common), [nixos](nixos) |
| `builder3` | CI VM | Additional builder VM (same profile as `builder1`). | [nixos/default.nix](nixos/default.nix) | [common](common), [nixos](nixos) |
| `ci` | CI VM | GitHub Actions coordinator using the fleet's remote builders. | [nixos/ci/default.nix](nixos/ci/default.nix) | [common](common), [nixos](nixos) |

### Clients (macs, frame)

| Machine | Type | Purpose | Config | Includes |
| --- | --- | --- | --- | --- |
| `mair` | macOS (aarch64-darwin) | Personal Mac workstation. | [darwin/mair/default.nix](darwin/mair/default.nix) | [common](common), [darwin](darwin) |
| `mmini` | macOS (aarch64-darwin) | Mac mini workstation. | [darwin/default.nix](darwin/default.nix) | [common](common), [darwin](darwin) |
| `JGWXHWDL4X` | macOS (aarch64-darwin) | Work Mac. | [darwin/default.nix](darwin/default.nix) | [common](common), [darwin](darwin) |
| `frame` | NixOS (x86_64-linux) | Desktop workstation. | [nixos/frame/default.nix](nixos/frame/default.nix) | [common](common), [nixos](nixos) |

### Media servers

Jellyfin and Jellarr run on `beast`.

| Machine | Type | Purpose | Config | Includes |
| --- | --- | --- | --- | --- |
| `srvarr` | NixOS VM | Media automation stack (Arr suite). | [nixos/srvarr/default.nix](nixos/srvarr/default.nix) | [common](common), [nixos](nixos) |

### Infra services

| Machine | Type | Purpose | Config | Includes |
| --- | --- | --- | --- | --- |
| `fana` | NixOS VM | Local Grafana stack (Grafana + Prometheus + Loki + Alloy log shipping). | [nixos/fana/default.nix](nixos/fana/default.nix) | [common](common), [nixos](nixos) |
| `home` | NixOS VM | Home Assistant service. | [nixos/home/default.nix](nixos/home/default.nix) | [common](common), [nixos](nixos) |
| `pki` | NixOS VM | Home fleet control-plane VM for internal PKI, PKI rotation, and UniFi state sync. | [nixos/pki/default.nix](nixos/pki/default.nix) | [common](common), [nixos](nixos) |
| `gw` | Network VM | Minimal WireGuard gateway VM for remote LAN access. | [nixos/gw/default.nix](nixos/gw/default.nix) | [common](common), [nixos](nixos) |
| `org` | NixOS VM | Org software VM. Starter service: Vikunja with Prometheus metrics scraped by `fana`. | [nixos/org/default.nix](nixos/org/default.nix) | [common](common), [nixos](nixos) |
