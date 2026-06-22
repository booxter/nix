# Agent Notes

Scope: the whole repository.

## Operating Boundaries

- Create local commits for completed changes. Do not push branches or deploy
  machines unless the user explicitly asks for that action.
- Avoid live, in-place changes on managed hosts, including the local machine.
  Prefer declarative changes in this Nix repository and let activation/deploy
  apply them. Only run imperative host changes when the user explicitly asks for
  that specific live action.
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
  `apps/`, encrypted host secrets under `secrets/`, and checks under
  `tests/` or `checks.nix`.

## Service-to-Service Security

- Secure communication between services by default, including internal
  node-to-node traffic. Prefer mTLS or a similarly authenticated and encrypted
  transport for new service endpoints; avoid unauthenticated plaintext listeners
  except for loopback-only endpoints or cases with an explicit, documented
  rationale.
- When adding a new communication channel between managed nodes, use the repo's
  PKI helper tools to issue/register the needed certificates and secrets rather
  than hand-rolling certificate material. Relevant flake apps include
  `issue-internal-service-cert` for internal HTTPS endpoints and
  `issue-observability-cert` for Prometheus/observability scrape channels.
- Model certificate wiring and trust declaratively in this repository, including
  any sops-nix secret material, service web configs, firewall exposure, and
  operational docs for the channel.

## SSH Access

- Use normal OpenSSH for access to managed hosts:

  ```sh
  ssh <target> [command ...]
  ```

- On configured clients, OpenSSH runs `ssh-ticket ensure` for known fleet hosts.
  It issues short-lived user certificates and may open a macOS TTL approval
  dialog followed by a Secretive/Touch ID prompt. Wait for user approval rather
  than bypassing the ticket flow.
- Existing valid tickets are reused automatically. Treat `ssh-ticket` and
  `ssht` as implementation details of the generated SSH config unless the user
  explicitly asks to debug ticket issuance.

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

`sops-edit` opens the host secret for editing. `sops-update` explicitly merges
template keys, `sops-cat` prints decrypted secrets, `sops-copy` copies one key
path between hosts, `sops-pass` writes password hashes, and `sops-bootstrap`
initializes a host secret and recipients.

## Monitoring

Grafana dashboards and alert rules cover fleet and service health. When adding
or changing a service, consider whether dashboards, Prometheus rules, alert
tests, or service metadata need updates too.
