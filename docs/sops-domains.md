# SOPS Secret Domains

Secrets are partitioned into cryptographically independent domains below
`secrets/`:

- `main` contains personal infrastructure secrets.
- `work` contains secrets for NVIDIA-managed machines.

Inventory selects a host's domain. SOPS helper apps select the domain of the
machine running them unless `--domain` is passed explicitly. An override only
changes path selection; the caller must still possess an identity listed by the
selected file's creation rule.

## Work identities

Each work host has an unattended native age identity at
`/var/lib/sops-nix/key.txt`. On macOS, manual work-domain operations use a
Secure Enclave identity at:

```text
~/Library/Application Support/sops/age/work.txt
```

The identity is created with `current-biometry`, binding its use to the Touch
ID fingerprints enrolled when it was generated. The file contains an opaque
Secure Enclave handle rather than the private key.

Bootstrap the current work Mac from a terminal with:

```sh
nix run .#sops-bootstrap -- --domain work --local "$(hostname -s)"
```

Work creation rules must not contain recipients present in `main` rules. The
SOPS configuration check enforces this invariant.

## Codex MaaS MCPs

JGW stores the NVIDIA MaaS Jira and Redmine endpoints at
`codex/mcp/maas_jira/url` and `codex/mcp/maas_redmine/url` in its work-domain
secret. During activation, `sops-nix` renders the endpoints into the protected
system Codex configuration; the plaintext values are not evaluated into the
Nix store.

After activating the configuration, authenticate with NVIDIA SSO:

```sh
codex mcp login maas_jira
codex mcp login maas_redmine
```

Codex stores the resulting OAuth credential in its local credential store. The
credential is not part of SOPS or the repository.

## Recovery

The work domain currently has no recovery recipient. Loss of both a host's
runtime identity and its Secure Enclave identity makes its secret file
unrecoverable. Store only regenerable values until a work-only recovery
recipient is configured.
