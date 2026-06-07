# Agent Notes

Scope: the whole repository.

## Operating Boundaries

- Create local commits for completed changes. Do not push branches or deploy
  machines unless the user explicitly asks for that action.
- Prefer the flake apps and repo scripts over ad hoc commands. Run `nix fmt`
  after Nix or Markdown edits.
- Keep unrelated working tree changes intact.

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
