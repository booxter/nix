# Builder access

Home builders have a dedicated `nix-ssh` account outside `trusted-users`, without
sudo or administrative group membership. SSH accepts only public keys from
`sshKeys.builders` and forces `nix-daemon --stdio`; shells, forwarding, user rc
files, and terminals are disabled. CI's key is accepted only on CI builders.
Linux uses `nix.sshServe`; Darwin provisions the equivalent account and admits it
to Apple's existing Remote Login allowlist without making it an administrator.

Each home client has a separate software SSH identity in the root-only SOPS
secret `nix/builder_private_key`. These keys do not authorize operator logins.
Work and community builders retain their separate access policies.

## Store signing

The participating hosts are mair, mmini, frame, ci, and builder1–3. Each daemon
automatically signs its build outputs using its own root-only
`nix/store_signing_key` secret. Participants trust the public keys in
`inventory/builders/signing-keys/`, alongside their configured cache keys.
Signed outputs can move through a client to another builder without granting
the SSH account Nix trust. Unsigned or untrusted input-addressed outputs are
rejected. Content-addressed inputs do not need signatures.

Store-signing keys are separate from hardware-backed Git signing. A stolen
builder SSH key permits builds, but does not by itself permit forging signed
inputs. A compromised store-signing key can poison imported contents; keep it
root-only and rotate it independently of SSH credentials. The Nix daemon reads
the key file when signing, so replacing its contents does not require a restart
to refresh an in-memory key.

## Rollout

The migration has two commits: provisioning first, then client cutover and
removal of old operator authorization. Deploy provisioning to all seven
participants before deploying cutover. Deploy cutover to other home hosts too
to remove their authorization of the old software operator keys. Do not deploy
cutover directly to an isolated client: its builders would lack the new account.

Automatic signing does not retroactively sign existing outputs. During the
provisioning phase, identify unsigned locally built outputs that will be reused
and either rebuild them with signing enabled or deliberately sign their reviewed
closures as root on the producing machine:

```console
sudo nix store sign --recursive \
  --key-file /run/secrets/nix/store_signing_key /nix/store/<reviewed-output>
```

Do not add a recurring blanket signing job or disable signature checks. Outputs
from other builders should carry those builders' signatures. Existing software
operator key files can be moved to `~/keys-backup` after cutover has been verified;
configuration changes do not move those files automatically.

## Verification

```console
nix build .#checks.x86_64-linux.builder-access --no-link
```

The VM test imports the production Linux server module. It verifies untrusted
connections, rejected shell/operator login/port forwarding, automatic local
signing, and transfer of a remote output through the client to another builder.
The receiving builder trusts only the producing builder's signing key. Unsigned
and untrusted-key inputs are rejected. Darwin account activation and hardware
operator authentication still need a live check after deployment.
