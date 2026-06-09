# PKI Rotation Plan

This repo manages internal PKI leaf certificates through encrypted host
secrets, so rotation should happen centrally from `prox-pkivm`, not on each
host. `pkivm` already runs `step-ca` and the issuer apps, and the fleet already
converges from Git state via the normal review and upgrade flow.

## Policy

- Root CA: no routine rotation
- Intermediate CA: no near-term work; rotate only as explicit maintenance
- Leaf server certs: `180d` lifetime
- Leaf client certs: `180d` lifetime
- Rotation threshold: rotate any managed leaf cert with `<= 45d` remaining

## Secret Access Model

`prox-pkivm` is a shared `sops` recipient for the fleet secrets. That lets the
rotation controller decrypt and re-encrypt repo-managed host secrets without
using a workstation-only age key.

This is intentional:

- the repo remains the source of truth for leaf certificates
- rotation happens in Git, not ad hoc on individual hosts
- normal review and rollout flow still applies to PKI changes

## Why PRs Instead Of Direct Push

- Secret updates stay reviewable.
- Rotation batches are visible in Git history.
- Existing repo checks gate cert changes before they reach the fleet.
- The source of truth remains the repo, not ad hoc state on individual hosts.

## Runtime Components

`prox-pkivm` runs two PKI jobs:

- `pki-status-export`
  - scans managed certificates
  - exports Prometheus textfile metrics through node exporter
  - covers internal root/intermediate CA state plus repo-managed internal leaf
    certs
- `pki-rotate`
  - runs on a timer
  - reuses the existing issuer apps for internal HTTPS, observability server,
    and mTLS client certs
  - clones the repo to a temporary worktree
  - updates encrypted host secrets for due leaf certs
  - force-pushes a dedicated automation branch
  - creates or updates a review PR instead of writing directly to the tracked
    branch

The controller branch is `ci/pki-rotate`, targeting the fleet’s normal base
branch.

## Rotation Flow

1. `pki-rotate` scans the repo-managed internal leaf inventory.
2. If no leaf cert is inside the `45d` rotation window, the run exits cleanly.
3. If one or more leaf certs are due, `pki-rotate` reissues them from the local
   `step-ca` on `prox-pkivm`.
4. Updated certs are written back into the corresponding `secrets/*.yaml`
   files.
5. The controller commits those encrypted updates to `ci/pki-rotate`.
6. It opens or updates a PR against the base branch.
7. After review and merge, the existing upgrade and deploy flow rolls the new
   certs out to the fleet.

The controller is idempotent. If an open rotation PR already exists, the job
works on that branch instead of re-creating the change from the base branch.

## Monitoring

PKI monitoring is split into internal managed cert state and public HTTPS state.

Internal metrics come from `pki-status-export` on `prox-pkivm`:

- root CA expiry
- intermediate CA expiry
- internal HTTPS server cert expiry
- Prometheus mTLS endpoint cert expiry
- internal mTLS client cert expiry
- cert parse/presence failures
- whether a cert is already inside the `45d` rotation window

Public HTTPS expiry continues to come from the existing blackbox SSL probe
metrics for public endpoints.

Grafana uses both sources in one PKI/TLS dashboard:

- internal cert parse health
- internal cert days remaining
- internal certs already inside the rotation window
- public HTTPS days remaining
- rotation controller last result and staleness

Suggested alerts:

- warning: managed or public cert `<= 30d`
- critical: managed or public cert `<= 14d`
- critical: managed cert missing or unparsable
- warning: rotation controller failed
- warning: rotation controller has gone stale

## Managed Scope

This rotation design covers repo-managed leaf certs only:

- internal HTTPS server certs
- Prometheus mTLS endpoint certs
- internal service mTLS client certs
- observability client certs such as Loki writers

It does not imply routine rotation of the root or intermediate CA.

## Operational Requirements

- `pkivm` needs GitHub credentials that can push a branch and open a PR
- store that credential in `secrets/pki.yaml` at
  `github.pki_rotation.token`
- the token only needs repository `Contents: Read and write` and `Pull requests:
  Read and write` on `booxter/nix`
- the controller depends on `step-ca`, `sops`, and the shared `pkivm` age key
  being present on the host
