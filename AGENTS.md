# Agent Notes

Scope: whole repository.

## Operating Rules

- Commit completed changes locally. Do not push, deploy, or change managed hosts
  live unless explicitly asked.
- Keep history clean: use separate commits for distinct logical steps and avoid
  spurious or unrelated changes.
- Prefer simple, task-focused solutions over over-engineering. Do not copy and
  paste shared patterns; refactor them when useful, normally in a separate
  commit.
- Prefer declarative Nix changes; keep unrelated worktree changes intact.
- Treat in-tree Nix modules, mixins, and options as internal to this repository.
  When editing them, update all in-repo call sites and do not preserve legacy
  aliases, compatibility shims, or backwards-compatible option names solely for
  out-of-tree consumers.
- Never modify, restore, reformat, stage, or commit changes you did not produce.
  Unrelated dirty files may be human edits or another agent working in parallel.
  Do not try to repair, revert, or normalize unrelated dirty paths.
- Prefer flake apps/repo scripts over ad hoc commands. Check `--help` when unsure.
- Prefer dependencies and packages already available from nixpkgs before adding
  local package definitions or vendored sources.
- Do not trim unchanged context from vendored patches. Patches should carry
  forward to new upstream versions only when the surrounding code still
  matches.
- Prefer third-party projects with a clear versioning story, especially tagged
  releases. If using an untagged revision, document the rationale and update
  path.
- When adding a local package pinned to an upstream version, wire it into the
  update-packages CI machinery so new releases are tracked. Do the same for
  pinned OCI image versions through the OCI image update machinery.
- Run `nix fmt` after edits; it also runs repo lint checks.

## Layout

- Host config: `nixos/<host>/`, `darwin/<host>/`; host-local packages:
  `<host>/pkgs/`.
- Shared modules: `common/_mixins/`, `nixos/_mixins/`, `darwin/_mixins/`,
  `home-manager/_mixins/`.
- Fleet facts: `lib/inventory.nix`.
- Shared packages: `pkgs/`; checkout-run apps/scripts: `apps/`.
- Secrets: `secrets/`; checks: `tests/`, `checks.nix`.

## Application Development

- New apps and helpers are Python, not shell. Allow shell only for tiny,
  inherently shell-facing glue. In Python, use native APIs and argument-list
  subprocess calls; no embedded shell or `shell=True` unless strictly required.
  Consider Go or Rust for larger applications and systems-level work.
- Python apps are `pyproject.toml` projects with `src/` packages and console
  entry points, never loose `.py` files. Require full typing, strict mypy, Ruff,
  and explicit models such as dataclasses instead of untyped dictionaries.
- Put I/O and external commands behind narrow injected interfaces (`Protocol`).
  Test with explicit fakes, not mocks, implementation monkeypatches, or global
  mutable hooks.
- Test behavior and failures, not generated source or implementation text. Keep
  tests beside the package and run pytest with coverage and a minimum threshold
  in Nix `checkPhase`; keep package tests out of top-level `tests/`.
- Every package must be built by a consumer or CI. Check shared portable apps on
  both Linux and macOS; keep host-specific packages under that host's `pkgs/`.
- Parse and emit JSON, YAML, and similar formats with libraries, never string
  concatenation or hand-written serialization templates.
- Declare and wrap external runtime executables; build inputs alone do not put
  programs on the installed runtime `PATH`.
- Assume Nix on managed machines. Build for the target system and use `nix copy`
  for closures, not `scp`, copied sources, or host-architecture executables.

## Security

- Secure service-to-service traffic by default. Prefer mTLS/authenticated
  encrypted transports; use plaintext only on loopback or with documented
  rationale.
- Services should use OIDC/SSO where the application supports it. Keep
  username/password fallback only when it is needed for rollback,
  mobile/native clients, API clients, or service-specific compatibility.
- For new managed-node channels, use repo PKI helpers:
  `issue-internal-service-cert` for internal HTTPS and
  `issue-observability-cert` for Prometheus/observability.
- Model certs, trust, sops-nix secrets, web config, firewall rules, and relevant
  docs declaratively.

## SSH

- Use normal OpenSSH:

  ```sh
  ssh <target> [command ...]
  ```

- On configured clients, OpenSSH transparently runs `ssh-ticket ensure`; wait for
  any macOS TTL/Secretive approval prompts. Treat `ssh-ticket`/`ssht` as
  implementation details unless explicitly debugging ticket issuance.
- For one-off remote diagnostics when a tool is missing on the target, it is ok
  to use `nix shell nixpkgs#<pkg> -c <cmd>`.

## Deploys

```sh
nix run .#deploy -- --branch <branch> <host>
```

- `deploy` clones the branch from GitHub, so unmerged local patches must be
  committed and pushed before deploy. Default branch: `master`.
- Use `--dry-run` for SSH/disk checks and `--test` for NixOS dry activation.
- Related apps: `prox-deploy` for Proxmox VMs, `vm` for local VM variants,
  `diff` for generated config comparisons.

## Secrets

Secrets use sops-nix, one encrypted YAML per host under `secrets/`.

```sh
nix run .#sops-cat -- [host]
nix run .#sops-edit -- [host]
nix run .#sops-update -- [host]
nix run .#sops-copy -- <from-host> <to-host> <key>
nix run .#sops-pass -- [--gen] <host> <user|both>
nix run .#sops-bootstrap -- <host>
```

- Do not run SOPS helpers that modify secrets in parallel; serialize them to
  avoid races.

## Monitoring

When adding/changing services, consider Grafana dashboards, Prometheus rules,
alert tests, and service metadata.
