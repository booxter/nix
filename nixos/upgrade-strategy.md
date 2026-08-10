# Upgrade Strategy

This repo uses a two-stage flow:

1. GitHub bumps flake inputs on a fixed morning schedule.
2. `mmini` warms the LAN Attic cache by building and pushing the non-work
   CI-validated outputs. The work laptop warms the work outputs locally without
   pushing to Attic.

The point of the warmup is to make the next maintenance window and later
interactive work substitute from the LAN cache instead of rebuilding or
downloading on demand.

## Rationale

NixOS modules contribute maintenance claims instead of assigning calendars to
individual hosts. The auto-upgrade planner combines those claims and allocates
deterministic slots inside the fleet's midnight-to-06:00 maintenance window.

The current claims enforce these rules:

- Builders, the Attic server, and Proxmox nodes use weekly Monday maintenance.
- Members of a builder pool and nodes in a Proxmox cluster receive distinct
  slots.
- Attic clients do not overlap the Attic server.
- Proxmox guests do not overlap nodes in their cluster.
- Remote storage consumers do not overlap their storage provider.
- Interactive services such as Jellyfin and Lolek request a separate weekly
  Saturday reboot while retaining daily non-rebooting upgrades.
- Hosts requiring interactive LUKS unlock never reboot automatically.
- Regular NixOS machines retain the daily `05:15` preference unless a
  relationship requires another slot.
- Run local backup work before the daily upgrade window on machines that have
  local backups. Application-specific prep runs first, then restic pushes to
  `beast`, then those machines may enter the daily upgrade/reboot window.
- Run the morning flake update after the upgrade windows. Once the PR is merged,
  `mmini` warms the LAN cache later that morning so the resulting closures are
  ready for the next upgrade window.

## Time Table

All times below are in `America/New_York`.

<!-- markdownlint-disable MD013 -->
| Time | Event | Notes |
| --- | --- | --- |
| `06:00` daily | Flake input bump workflow | GitHub Actions runs `.github/workflows/auto-update.yml`, updates `flake.lock`, and opens a PR. |
| `08:30` and `20:30` daily | LAN cache warmup | `mmini` runs `fleet-cache-warmer` as a `launchd` daemon and pushes the realized non-work closures into Attic. |
| `00:00`, `00:40`, `01:20`, and `02:40` Monday | Home-realm builder maintenance | Builder-pool claims stagger `builder1`, `builder2`, `builder3`, and `frame`; `frame` does not reboot. |
| `02:00` Monday | `cache` maintenance | Attic client/server exclusions keep cache consumers out of this slot. |
| `02:40`, `03:20`, and `04:40` Monday | Proxmox lab node maintenance | Cluster and guest claims preserve node and guest availability. |
| `05:15` daily | Default NixOS upgrade window | Most NixOS hosts inherit this from `nixos/default.nix`. |
| `03:20` Saturday | `beast` conditional reboot | Jellyfin and Lolek request a weekly interactive-service reboot; storage relationships keep it separate from consumers. |
<!-- markdownlint-enable MD013 -->

The planner treats the five-minute randomized delay as part of every occupied
slot. Static scheduling prevents planned windows from overlapping; runtime
maintenance guards still handle live conditions such as active Jellyfin
playback. The authoritative result is
`host.autoUpgrade.plan` in each evaluated NixOS configuration. Run
`nix run .#upgrade-show` to display the complete fleet plan and its contributing
claims.

## Warmup Scope

`fleet-cache-warmer` builds the selected CI-validated Nix outputs below. On
`mmini`, it selects home-realm targets and pushes them to Attic. On
`JGWXHWDL4X`, it selects work-realm targets and only realizes them in the local
Nix store.

- `x86_64-linux` NixOS system closures
- `x86_64-linux` VM artifacts used by CI
- `aarch64-darwin` system and VM outputs that CI validates

The home-realm warmer excludes:

- targets selected exclusively for hosts in another realm
- formatting checks such as `nix fmt`

Those excluded items do not belong in the home cache or do not produce useful
Nix store closures for Attic warming.

The authoritative source for these targets at system build time is
[`ci/default.nix`](/Users/ihrachyshka/src/nix/ci/default.nix:1).
Both CI and the `fleet-cache-warmer` package read from that facts. Every
target has an owning host, and the warmer selects targets whose host belongs to
its configured realm in
[`facts/default.nix`](/Users/ihrachyshka/src/nix/facts/default.nix:1).
The filtered list is embedded in the installed launchd closure.

## Why `mmini`

`mmini` is the non-work warmup orchestrator because it can:

- run unattended on a stable always-on Darwin machine
- delegate `x86_64-linux` builds to the configured remote builders
- push realized outputs into the personal Attic cache using the root-managed
  Attic client config

`cache` remains the Attic server. It is not the build orchestrator.

`JGWXHWDL4X` runs the work warmup without pushing because its realm has no
Attic server. It uses configured Nix remote builders for work Linux targets.

## Procedure

The daily home-realm warmup procedure is:

1. `launchd` starts `fleet-cache-warmer` on `mmini` at `08:30` and `20:30`.
2. The warmer uses the target list embedded in its installed launchd closure and
   builds those attributes from `github:booxter/nix`.
3. The warmer selects targets belonging to the host's declared realm.
4. The warmer filters out facts entries that no longer evaluate at that
   flake revision.
5. The warmer builds the remaining targets in one `nix build --keep-going`
   invocation so Nix can schedule work across the available builders. Warmers
   that push to Attic cap substitution jobs at 4 and HTTP connections at 8 to
   avoid exhausting Attic's SQLite connection pool. If that batched build
   produces no successful outputs, it falls back to target-by-target builds.
6. Missing or broken targets are logged and skipped so one failure does not
   abort the whole run.
7. If the realm has Attic servers, the warmer explicitly pushes the resulting
   store paths into every discovered Attic cache with
   `--ignore-upstream-cache-filter`.
8. Later fleet upgrades substitute from `http://nix-cache:8080/default/` when
   those closures are needed.

The explicit `attic push` step matters. The repo's background
`attic watch-store` service is enough for locally built outputs, but it still
honors Attic's upstream cache filter. The warmer uses
`--ignore-upstream-cache-filter` so already-substituted targets still get
rehomed into the local cache.

## Logs

Warmup logs are written to:

```text
/var/log/fleet-cache-warmer.log
```
