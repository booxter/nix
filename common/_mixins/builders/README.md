# Builder access

Home builders currently accept the operators' software SSH keys as the personal
login account. That account is also trusted by the Nix daemon. Restricting an
SSH key to `nix-daemon --stdio` removes shell access, but does not remove the
account's Nix trust. The existing builder credentials and authorization remain
in place pending the separation below.

## Tested account separation

Run the isolated Linux integration test with:

```console
nix build .#checks.x86_64-linux.builder-access --no-link
```

The test uses a dedicated `remote-builder` account in `allowed-users`, outside
`trusted-users`, with a software SSH key restricted to `nix-daemon --stdio`.
With the repository's pinned Nix, it verifies:

- Nix reports the connection as untrusted.
- The key cannot execute shell commands, log in as the operator, or forward a
  TCP port.
- A remote build succeeds and returns its output to the client.
- A build that needs an unsigned, locally built input fails during transfer.
- Signing that same input with a store key trusted by the builder lets the
  build succeed.

This validates the Linux protocol flow, not a deployed fleet configuration or
Darwin account setup. It does not establish that every derivation type works
through an untrusted connection.

## Remaining migration

Use a dedicated builder account without sudo or administrative group membership,
root-managed restricted authorized keys, and separate software client keys held
by the Nix daemon. Remove the old software identities from general operator
authorization after clients have switched. Community builder access remains
separate.

Before switching, choose how locally built inputs acquire trusted store
signatures: a controlled cache workflow or daemon-managed signing keys. Store
signatures are separate from hardware-backed Git signing. Store signing grants
authority over imported contents, so its keys and signing policy need their own
review; automatically signing arbitrary supplied paths would undermine the
separation. Do not solve failed transfers by disabling signature checks or
making the builder account a trusted user.
