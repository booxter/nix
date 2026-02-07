# Nix configs

This repo uses a `Makefile` as the main entrypoint for building and switching
configurations. Most targets take `WHAT=` (a host or VM type). Running a target
without `WHAT` prints the available options when supported.

## Common commands

```sh
make inputs-update
make nixos-build-target WHAT=frame
make darwin-build-target WHAT=mair

```

## Local and CI VMs

```sh
make local-vm WHAT=builder1
make build-local-vm WHAT=builder1

make ci-vm WHAT=builder1
make build-ci-vm WHAT=builder1
make build-ci-vm-config WHAT=builder1
```

## Proxmox VMs

```sh
make prox-vm WHAT=jellyfin WHERE=prx1
```

## Host rebuilds

```sh
make nixos-build
make nixos-switch

make darwin-build
make darwin-switch
```

## Fleet updates

Update multiple machines over SSH with `scripts/update-machines.sh` (defaults to `--all`):

```sh
# Update all personal machines (default)
./scripts/update-machines.sh -A

# Update all work machines
./scripts/update-machines.sh -A --work

# Update a subset interactively (fzf required)
./scripts/update-machines.sh -A --select

# Dry run (SSH check + disk estimate only)
./scripts/update-machines.sh -A --dry-run
```

## Disk and image helpers

```sh
make disko-install WHAT=frame DEV=/dev/sdX
make pi-image
```

## Secrets

Secrets are managed via sops-nix, with one encrypted YAML per host under `secrets/`.
Optional templates can live in `secrets/_templates/` to prefill host-specific keys.

Bootstrap (beast example):

```sh
scripts/sops-bootstrap-remote.sh --host beast
```

This will:
- create `/var/lib/sops-nix/key.txt` on the host (if missing)
- fetch the age public key
- create `.sops.yaml` if needed (or patch it)
- create `secrets/beast.yaml` encrypted with that key

Afterwards, edit the secret with:

```sh
scripts/sops-edit.sh --host beast
```

## Home Manager

```sh
make home-build-nv
make home-switch-nv
```

## Machines

All VMs run on Proxmox hosts and are deployed with the `nixmoxer` tool
(`scripts/push-vm-to-proxmox.sh`).

### Infra (DHCP, Proxmox)

| Machine | Type | Purpose | Config | Includes |
| --- | --- | --- | --- | --- |
| `pi5` | NixOS (Raspberry Pi) | DHCP and network services for the lab. | [nixos/pi5/default.nix](nixos/pi5/default.nix) | [common](common), [nixos](nixos) |
| `beast` | NixOS (x86_64-linux) | NAS storage server. | [nixos/beast/default.nix](nixos/beast/default.nix) | [common](common), [nixos](nixos) |
| `nvws` | Proxmox host | Work Proxmox node configuration. Single node. | [nixos/nvws/default.nix](nixos/nvws/default.nix) | [common](common), [nixos](nixos) |
| `prx1-lab` | Proxmox host | Lab Proxmox node (cluster leader). | [nixos/prx1-lab/default.nix](nixos/prx1-lab/default.nix) | [common](common), [nixos](nixos) |
| `prx2-lab` | Proxmox host | Lab Proxmox node (cluster member). | [nixos/prx2-lab/default.nix](nixos/prx2-lab/default.nix) | [common](common), [nixos](nixos) |
| `prx3-lab` | Proxmox host | Lab Proxmox node (cluster member). | [nixos/prx3-lab/default.nix](nixos/prx3-lab/default.nix) | [common](common), [nixos](nixos) |

### Nix infra

| Machine | Type | Purpose | Config | Includes |
| --- | --- | --- | --- | --- |
| `builder1` | CI VM | Primary builder VM for CI and heavy Nix builds. | [nixos/default.nix](nixos/default.nix) | [common](common), [nixos](nixos) |
| `builder2` | CI VM | Additional builder VM (same profile as `builder1`). | [nixos/default.nix](nixos/default.nix) | [common](common), [nixos](nixos) |
| `builder3` | CI VM | Additional builder VM (same profile as `builder1`). | [nixos/default.nix](nixos/default.nix) | [common](common), [nixos](nixos) |
| `cache` | CI VM | Cache VM backed by NFS for binary caching. | [nixos/cachevm/default.nix](nixos/cachevm/default.nix) | [common](common), [nixos](nixos) |

### Clients (macs, frame)

| Machine | Type | Purpose | Config | Includes |
| --- | --- | --- | --- | --- |
| `mair` | macOS (aarch64-darwin) | Personal Mac workstation. | [darwin/mair/default.nix](darwin/mair/default.nix) | [common](common), [darwin](darwin) |
| `mmini` | macOS (aarch64-darwin) | Mac mini workstation. | [darwin/default.nix](darwin/default.nix) | [common](common), [darwin](darwin) |
| `JGWXHWDL4X` | macOS (aarch64-darwin) | Work Mac. | [darwin/default.nix](darwin/default.nix) | [common](common), [darwin](darwin) |
| `frame` | NixOS (x86_64-linux) | Desktop workstation. | [nixos/frame/default.nix](nixos/frame/default.nix) | [common](common), [nixos](nixos) |


### Media servers

| Machine | Type | Purpose | Config | Includes |
| --- | --- | --- | --- | --- |
| `jellyfin` | NixOS VM | Media server (Jellyfin). | [nixos/jellyfinvm/default.nix](nixos/jellyfinvm/default.nix) | [common](common), [nixos](nixos) |
| `srvarr` | NixOS VM | Media automation stack (Arr suite). | [nixos/srvarrvm/default.nix](nixos/srvarrvm/default.nix) | [common](common), [nixos](nixos) |
