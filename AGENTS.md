# Agent Notes

Scope: the whole repository.

## Operating Boundaries

- Create local commits for completed changes. Do not push branches or deploy
  machines unless the user explicitly asks for that action.
- Prefer the flake apps and repo scripts over ad hoc commands. Run `nix fmt`
  after edits; it applies the repo's format and lint rules.
- Most flake apps and scripts support `--help`; check that before guessing
  flags.
- Keep unrelated working tree changes intact.

## Repository Structure

- Host-specific configuration lives under `nixos/<host>/` and
  `darwin/<host>/`. Add machine-local service/config changes there.
- Shared modules live in `common/_mixins/`, `nixos/_mixins/`,
  `darwin/_mixins/`, and `home-manager/_mixins/`.
- Static fleet facts belong in `lib/inventory.nix`: host lists, addresses,
  aliases, DNS/service metadata, and shared public keys.
- Custom packages and tools live under `pkgs/`, script entrypoints under
  `scripts/`, encrypted host secrets under `secrets/`, and checks under
  `tests/` or `checks.nix`.

## SSH Access

- Use `ssht` for SSH access to managed NixOS nodes:

  ```sh
  ssht <target> [command ...]
  ssh-ticket status [target]
  ssh-ticket targets
  ```

- `ssht` issues short-lived user certificates and may open a macOS TTL approval
  dialog followed by a Secretive/Touch ID prompt. Wait for user approval rather
  than falling back to raw SSH.
- Existing valid tickets are reused. Use `--force` only when intentionally
  testing ticket issuance.
- `ssh-ticket` manages ticket targets, status, and explicit ticket issuance;
  `ssht` is the normal SSH wrapper that issues or reuses a ticket and then runs
  `ssh`.

## Deploys

- Fleet deploys use:

  ```sh
  nix run .#deploy -- --branch <branch> <host>
  ```

- The deploy script clones the requested branch from GitHub. For unmerged local
  patches, commit them and have the branch pushed before deploying with
  `--branch`; otherwise the remote host will not see the changes.
- The default deploy branch is `master`. Use `--dry-run` for SSH/disk checks and
  `--test` for NixOS dry activation.
- `deploy` updates existing NixOS/nix-darwin machines over SSH. `prox-deploy`
  creates or updates Proxmox VMs. `vm` runs local VM variants. `diff` compares
  generated system configs between Git revisions.

## Secrets

Secrets are managed by sops-nix, with one encrypted host YAML under `secrets/`.
Use the flake helpers:

```sh
nix run .#sops-cat -- [host]
nix run .#sops-edit -- [host]
nix run .#sops-update -- [host]
nix run .#sops-copy -- <from-host> <to-host> <key>
nix run .#sops-pass -- [--gen] <host> <user|both>
nix run .#sops-bootstrap -- <host>
```

`sops-edit` merges missing template keys before opening the editor.
`sops-update` only merges template keys, `sops-cat` prints decrypted secrets,
`sops-copy` copies one key path between hosts, `sops-pass` writes password
hashes, and `sops-bootstrap` initializes a host secret and recipients.
