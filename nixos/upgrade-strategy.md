# Upgrade Strategy

This repo uses a two-stage flow:

1. GitHub bumps flake inputs on a fixed morning schedule.
2. `mmini` warms the LAN Attic cache by building and pushing the same
   CI-validated outputs.

The point of the warmup is to make the next upgrade window and later interactive
work substitute from the LAN cache instead of rebuilding or downloading on
demand.

## Rationale

The schedule is organized around a few ordering rules:

- Update infrastructure first on Monday morning: Nix builder VMs, then
  `cachevm`, then Proxmox nodes. These machines support or host the rest of the
  fleet, so they get a separate maintenance lane.
- Keep regular NixOS machines on a daily cadence. Hosts that inherit the default
  `nixos/default.nix` schedule upgrade every morning instead of waiting for a
  weekly batch.
- Run local backup work before the daily upgrade window on machines that have
  local backups. Application-specific prep runs first, then restic pushes to
  `beast`, then those machines may enter the daily upgrade/reboot window.
- Run the morning flake update after the upgrade windows. If the PR merges,
  `mmini` warms the LAN cache later that morning so the resulting closures are
  ready for the next upgrade window.

## Time Table

All times below are in `America/New_York`.

<!-- markdownlint-disable MD013 -->
| Time | Event | Notes |
| --- | --- | --- |
| `06:00` daily | Flake input bump workflow | GitHub Actions runs `.github/workflows/auto-update.yml`, updates `flake.lock`, opens a PR, and enables auto-merge. |
| `08:30` daily | LAN cache warmup | `mmini` runs `fleet-cache-warmer` as a `launchd` daemon and pushes the realized closures into Attic. |
| `03:00` Monday | Nix builder VM upgrade window | Set in `lib/inventory.nix` for `prox-builder1vm`, `prox-builder2vm`, and `prox-builder3vm`. |
| `03:30` Monday | `cachevm` upgrade window | Set in `nixos/cachevm/default.nix`. |
| `04:00` Monday | Proxmox hypervisor upgrade window | Set in `lib/helpers.nix` for Proxmox hosts. |
| `05:15` daily | Default NixOS upgrade window | Most NixOS hosts inherit this from `nixos/default.nix`. |
<!-- markdownlint-enable MD013 -->

`system.autoUpgrade.randomizedDelaySec = 5min` is enabled for the fleet, so
actual upgrade start time may drift within that window. `frame` still upgrades
on schedule but does not auto-reboot.

## Warmup Scope

`fleet-cache-warmer` builds and pushes the CI-validated Nix outputs below:

- `x86_64-linux` NixOS system closures
- `aarch64-linux` NixOS system closures
- `x86_64-linux` VM artifacts used by CI
- `aarch64-darwin` system and VM outputs that CI validates
- `x86_64-linux` regular checks from `.github/workflows/checks.yml`
- `x86_64-linux` NixOS tests from `.github/workflows/checks.yml`

It intentionally excludes:

- formatting checks such as `nix fmt`
- shell-only CI steps such as `./tests/test-get-hosts.sh`

Those excluded items either are not warmed yet by policy or do not produce
useful Nix store closures for Attic warming.

The authoritative source for these targets is
[`ci-target-inventory.json`](/Users/ihrachyshka/src/nix/ci-target-inventory.json:1).
Both CI and `fleet-cache-warmer` read from that inventory so the target list is
maintained in one place.

## Why `mmini`

`mmini` is the warmup orchestrator because it can:

- run unattended on a stable always-on Darwin machine
- delegate `x86_64-linux` builds to the configured remote builders
- push realized outputs into the personal Attic cache using the root-managed
  Attic client config

`cachevm` remains the Attic server. It is not the build orchestrator.

## Procedure

The daily warmup procedure is:

1. `launchd` starts `fleet-cache-warmer` on `mmini` at `08:30`.
2. The warmer reads the warm target inventory from the same flake revision it is
   about to build from `github:booxter/nix`.
3. The warmer first filters out inventory entries that no longer evaluate at
   that flake revision.
4. The warmer builds the remaining targets in one `nix build --keep-going`
   invocation so Nix can schedule work across the available builders. If that
   batched build produces no successful outputs, it falls back to target-by-target
   builds.
5. Missing or broken targets are logged and skipped so one failure does not
   abort the whole run.
6. The warmer explicitly pushes the resulting store paths into the `default`
   Attic cache with `--ignore-upstream-cache-filter`.
7. Later fleet upgrades substitute from `http://nix-cache:8080/default/` when
   those closures are needed.

The explicit `attic push` step matters. The repo's background
`attic watch-store` service is enough for locally built outputs, but it still
honors Attic's upstream cache filter. The warmer uses
`--ignore-upstream-cache-filter` so already-substituted targets still get
rehomed into the local cache.

## Manual Operation

Useful commands on `mmini`:

```bash
sudo fleet-cache-warmer --print-targets
sudo fleet-cache-warmer
```

Logs are written to:

```text
/var/log/fleet-cache-warmer.log
```
