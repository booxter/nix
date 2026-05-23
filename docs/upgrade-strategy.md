# Upgrade Strategy

This repo uses a two-stage flow:

1. GitHub bumps flake inputs on a fixed morning schedule.
2. `mmini` warms the LAN Attic cache by building and pushing the same
   CI-validated outputs.

The point of the warmup is to make the next upgrade window and later interactive
work substitute from the LAN cache instead of rebuilding or downloading on
demand.

## Time Table

All times below are in `America/New_York`.

<!-- markdownlint-disable MD013 -->
| Time | Event | Notes |
| --- | --- | --- |
| `05:00` daily | Flake input bump workflow | GitHub Actions runs `.github/workflows/auto-update.yml`, updates `flake.lock`, opens a PR, and enables auto-merge. |
| `07:30` daily | LAN cache warmup | `mmini` runs `fleet-cache-warmer` as a `launchd` daemon and pushes the realized closures into Attic. |
| `04:00` Saturday | Default NixOS upgrade window | Most NixOS hosts inherit this from `nixos/default.nix`. |
| `04:00` Sunday | Proxmox hypervisor upgrade window | Set in `lib/helpers.nix` for Proxmox hosts. |
| `04:00` Monday | `beast` upgrade window | Set in `nixos/beast/default.nix`. |
| `04:00` Tuesday | `cachevm` upgrade window | Set in `nixos/cachevm/default.nix`. |
<!-- markdownlint-enable MD013 -->

`system.autoUpgrade.randomizedDelaySec = 15min` is enabled for the fleet, so
actual upgrade start time may drift within that window. `frame` still upgrades
on schedule but does not auto-reboot.

## Warmup Scope

`fleet-cache-warmer` builds and pushes the CI-validated Nix outputs below:

- `x86_64-linux` NixOS system closures
- `aarch64-linux` NixOS system closures
- `x86_64-linux` VM artifacts used by CI
- `x86_64-linux` Home Manager activation for `nv`
- `aarch64-darwin` system, Home Manager, and VM outputs that CI validates
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

1. `launchd` starts `fleet-cache-warmer` on `mmini` at `07:30`.
2. The warmer reads the warm target inventory from the same flake revision it is
   about to build from `github:booxter/nix`.
3. The warmer builds those targets one by one. Missing or broken targets are
   logged and skipped so one failure does not abort the whole run.
4. The warmer explicitly pushes the resulting store paths into the `default`
   Attic cache with `--ignore-upstream-cache-filter`.
5. Later fleet upgrades substitute from `http://nix-cache:8080/default/` when
   those closures are needed.

The explicit `attic push` step matters. The repo's `post-build-hook` is not
enough for cache warming because substituted paths do not trigger Nix
`post-build-hook`.

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
