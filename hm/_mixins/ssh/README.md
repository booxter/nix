# Operator SSH credentials

Home operators sign Git commits and tags with the hardware identities in
`sshKeys.hardware`. Git selects an approved public key from the current SSH
agent; other agent keys cannot become a signing fallback.

On a local YubiKey session, the selector first loads the configured hardware
handle into the local agent. Inside SSH, it only uses the forwarded agent, so
approval happens on the originating machine. Without an approved agent key,
signing fails instead of using a software key or the destination's hardware.

Frame's pre-boot SSH unlock accepts the mair Secretive key and the shared
YubiKey identity used from mmini. SSH authentication starts the restricted disk
unlock command; the disk passphrase is still required.

Home builds use separate root-only software keys and an untrusted `nix-ssh`
account. The old operator `id_ed25519` public keys no longer authorize home
logins. See [builder access](../../../common/_mixins/builders/README.md) for the
staged rollout and store-signing policy before retiring their local files.
Community builders use the separate `nix-community-builders` key.
