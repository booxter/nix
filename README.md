# Nix configs

This repo uses a `Makefile` as the main entrypoint for builds and local VM
workflows. Most targets take `WHAT=` (a host or VM type). Running a target
without `WHAT` prints the available options when supported.

## Common commands

```sh
make nixos-build-target WHAT=frame
make darwin-build-target WHAT=mair

```

## Local and NixOS VMs

```sh
make local-vm WHAT=builder1
```

## Proxmox VMs

```sh
nix run .#prox-deploy -- srvarr prx1
```

## Host rebuilds

```sh
make nixos-build-target WHAT=beast REMOTE=false
make darwin-build-target WHAT=mair
```

## Fleet updates

Update multiple machines over SSH with `nix run .#fleet-apply` (defaults to
`--all`):

```sh
# Update all personal machines (default)
nix run .#fleet-apply -- -A

# Update all work machines
nix run .#fleet-apply -- -A --work

# Update a subset interactively (fzf required)
nix run .#fleet-apply -- -A --select

# Dry run (SSH check + disk estimate only)
nix run .#fleet-apply -- -A --dry-run
```

## Disk and image helpers

```sh
nix run .#fleet-apply -- --disko frame /dev/sdX
nix build .#pi-image -o pi5.sd
```

## Secrets

Secrets are managed via sops-nix, with one encrypted YAML per host under `secrets/`.
The shared plaintext seed template is `secrets/_template.yaml`.
Use flake apps for bootstrap so required tools are provided automatically.

Bootstrap a remote host over SSH (beast example):

```sh
nix run .#sops-bootstrap -- beast
```

If SSH user differs from your local username:

```sh
nix run .#sops-bootstrap -- beast --user root
```

This will:

- create `/var/lib/sops-nix/key.txt` on the host (if missing)
- fetch the age public key
- create `.sops.yaml` if needed (or patch it), including your local age key as a
  recipient for that host rule
- create `secrets/beast.yaml` encrypted using `.sops.yaml` creation rules

Notes:

- `sops-bootstrap` needs a real terminal (`ssh -tt`) because it may prompt for
  remote `sudo` password.
- It reads your local age key from `$SOPS_AGE_KEY_FILE` or `~/.config/sops/age/keys.txt`.

Afterwards, edit the secret with:

```sh
nix run .#sops-edit -- beast
```

For the current host (detected via `hostname -s`), you can omit the host argument:

```sh
nix run .#sops-cat
nix run .#sops-edit
nix run .#sops-update
```

Or pass a host name as a positional argument:

```sh
nix run .#sops-cat -- mair
nix run .#sops-edit -- mair
nix run .#sops-update -- mair
```

Copy a section between host secrets (example: copy `attic` from `mair` to `prx1-lab`):

```sh
nix run .#sops-copy -- mair prx1-lab attic
```

## Home Manager

```sh
make linux-home-build-target TARGET=nv
make darwin-home-build-target TARGET=mair
nix run .#fleet-apply -- --home nv
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
