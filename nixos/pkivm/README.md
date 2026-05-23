# prox-pkivm

## Goal

This VM is the dedicated internal PKI host for the home fleet.

The practical starting design is:

- root and intermediate CA material stored on `prox-pkivm`
- short-lived leaf certificates
- internal ACME plus mTLS for internal services

The later hardening path is:

- move the same root key offline
- rotate to a new online intermediate on `prox-pkivm`
- keep the already-distributed root trust anchor unchanged

## Phase 1

The first step is intentionally narrower:

- stand up `step-ca` on `prox-pkivm`
- bootstrap the CA state locally on first boot into `/var/lib/step-ca`
- keep this host off the current plaintext exporter pattern
- validate issuance and trust distribution before changing scrape traffic

This is the intended initial trust model for now, not an accident. The root key
starts online so the fleet can learn the operational path first. The key follow-up
is to move that root key offline later without changing the root certificate that
clients already trust.

## Follow-Up Path

Once the first CA server is up, the next steps are:

1. back up `/var/lib/step-ca` before relying on the CA for anything important
2. integrate one end-to-end mTLS path first
3. move the current root key offline and rotate to a new intermediate
4. reuse that pattern for the rest of the fleet

## Initial Scope

- `step-ca` listens on TCP `8443`
- ACME is enabled for later certificate issuance
- no exporter migration is included yet
- no fleet-wide trust distribution is included yet
- the CA should not be treated as durable until `/var/lib/step-ca`
  is covered by backups
