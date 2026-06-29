# Agent Notes

Scope: whole repository.

## Operating Rules

- Commit completed changes locally. Do not push, deploy, or change managed hosts
  live unless explicitly asked.
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
