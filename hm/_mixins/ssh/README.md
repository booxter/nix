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

The software `id_ed25519` identities still serve unattended home builds. Their
builder and operator authorization must be separated before those files can be
retired. Community builders use the separate `nix-community-builders` key.
