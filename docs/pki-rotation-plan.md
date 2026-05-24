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

## Target Workflow

1. A scheduled rotation job runs on `prox-pkivm`.
2. It inventories all managed internal leaf certs from repo-managed host
   secrets.
3. If no cert is within the `45d` threshold, it exits with no repo changes.
4. If one or more certs are due, it reissues them from `step-ca` and updates
   the corresponding `secrets/*.yaml` files.
5. Instead of pushing directly to the tracked branch, it creates a dedicated
   branch and opens a PR for review.
6. Normal CI runs on that PR.
7. After merge, the existing NixOS upgrade/deploy flow rolls the new certs out
   to hosts.

## Why PRs Instead Of Direct Push

- Secret updates stay reviewable.
- Rotation batches are visible in Git history.
- Existing repo checks gate cert changes before they reach the fleet.
- The source of truth remains the repo, not ad hoc state on individual hosts.

## Rotation Controller On `pkivm`

The rotation controller should:

- run on a timer, likely daily
- reuse the existing issuer logic for:
  - internal HTTPS service certs
  - observability server certs
  - observability and service mTLS client certs
- be idempotent
- batch all due rotations into one PR
- include a machine-readable summary of what was rotated and the new expiry
  dates

Operational prerequisites:

- `pkivm` needs GitHub credentials that can push a branch and open a PR
- store that credential in `secrets/prox-pkivm.yaml` at
  `github.pki_rotation.token`
- the job should target the repo branch that the fleet normally follows after
  review and merge

## Monitoring

Rotation should be paired with PKI status monitoring on `pkivm`.

Add a PKI status exporter or scheduled metrics collector that reports:

- internal root CA expiry
- internal intermediate CA expiry
- internal server leaf cert expiry
- internal client leaf cert expiry
- public Let’s Encrypt cert expiry for public endpoints

That data should feed a Grafana board that shows:

- days remaining by certificate
- certificates already inside the `45d` rotation window
- certificates inside alert windows
- last rotation run status

Suggested alerts:

- warning: `<= 30d` remaining
- critical: `<= 14d` remaining

## Scope Of Rotation

This plan covers repo-managed leaf certs only:

- internal HTTPS server certs
- Prometheus mTLS endpoint certs
- internal service mTLS client certs
- observability client certs such as Loki writers

It does not imply routine rotation of the root or intermediate CA.

## Implementation Order

1. Change leaf lifetime on `pkivm` from `30d` to `180d`.
2. Add PKI status collection and Grafana visibility.
3. Add expiry alerts.
4. Implement the PR-based rotation controller on `pkivm`.
5. Enable the timer once the dry-run and PR flow behave correctly.
