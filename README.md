# Nix configs

This repo provides flake apps and scripts as the primary interfaces. The
`Makefile` is a convenience wrapper for a few host/home build commands.

## Build and Deploy

```sh
# Host builds
make nixos WHAT=frame
make darwin WHAT=mair
make nixos WHAT=beast REMOTE=false

# Local VMs (any host with a `local-<host>vm` config)
nix run .#vm -- --help
nix run .#vm -- builder1
nix run .#vm -- srvarr

# Proxmox VM deploy
nix run .#prox-deploy -- srvarr prx1

# Disk and image helpers
nix run .#fleet-deploy -- --disko frame /dev/sdX
nix build .#pi-image -o pi5.sd
```

## Fleet updates

Update multiple machines over SSH with `nix run .#fleet-deploy` (defaults to
`--all`):

```sh
# Update all personal machines (default)
nix run .#fleet-deploy -- -A

# Update all work machines
nix run .#fleet-deploy -- -A --work

# Update a subset interactively
nix run .#fleet-deploy -- -A --select

# Dry run (SSH check + disk estimate only)
nix run .#fleet-deploy -- -A --dry-run
```

## Secrets

Secrets are managed via sops-nix, with one encrypted YAML per host under `secrets/`.
Use these commands:

```sh
# Bootstrap a host secret
nix run .#sops-bootstrap -- beast
nix run .#sops-bootstrap -- beast --user root

# Current host (detected from hostname)
nix run .#sops-cat
nix run .#sops-edit
nix run .#sops-update

# Explicit host
nix run .#sops-cat -- mair
nix run .#sops-edit -- mair
nix run .#sops-update -- mair

# Copy one section between host secrets
nix run .#sops-copy -- mair prx1-lab attic
```

## Home Manager

```sh
make linux-home TARGET=nv
make darwin-home TARGET=mair
nix run .#fleet-deploy -- --home nv
```

`TARGET` must match a standalone Home Manager profile from
`homeConfigurations` (the part after `${USERNAME}@`).

## Tests

Run Bats checks:

```sh
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
nix build ".#checks.${system}.bats-tests" --no-link
```

Run full flake checks (same entrypoint used in CI):

```sh
nix flake check -L --show-trace
```

## CI

CI matrix selection rules and skip behavior are documented in
[.github/README.md](.github/README.md).

## Machines

All VMs run on Proxmox hosts and are deployed with `prox-deploy` (wrapper
around `nixmoxer`).

### Infra (DHCP, Proxmox)

| Machine | Type | Purpose | Config | Includes |
| --- | --- | --- | --- | --- |
| `pi5` | NixOS (Raspberry Pi) | DHCP and network services for the lab. | [nixos/pi5/default.nix](nixos/pi5/default.nix) | [common](common), [nixos](nixos) |
| `beast` | NixOS (x86_64-linux) | NAS storage + Jellyfin/Jellarr server. | [nixos/beast/default.nix](nixos/beast/default.nix) | [common](common), [nixos](nixos) |
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

Jellyfin and Jellarr run on `beast`.

| Machine | Type | Purpose | Config | Includes |
| --- | --- | --- | --- | --- |
| `srvarr` | NixOS VM | Media automation stack (Arr suite). | [nixos/srvarrvm/default.nix](nixos/srvarrvm/default.nix) | [common](common), [nixos](nixos) |
