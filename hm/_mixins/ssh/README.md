# Operator SSH credentials

Operators sign Git commits and tags with the hardware identities in
`sshKeys.hardware`. Git selects an approved public key from the current SSH
agent; other agent keys cannot become a signing fallback.

On a local YubiKey session, the selector first loads the configured hardware
handles into the local agent. Inside SSH, it only uses the forwarded agent, so
approval happens on the originating machine. Without an approved agent key,
signing fails instead of using a software key or the destination's hardware.

The work realm authorizes both `work.main` and `work.laptop` YubiKeys. Their
serial numbers are recorded in [the YubiKey inventory](../../../inventory/yubikeys.nix),
and their public keys are in [the SSH inventory](../../../inventory/ssh/default.nix).
The work laptop offers `~/.ssh/id_ed25519_sk_work_main` first, followed by
`~/.ssh/id_ed25519_sk_work_laptop`. Other YubiKey clients default to
`~/.ssh/id_ed25519_sk_rk`; configure `host.ssh.credentials.yubikey.identityFiles`
to use different handle filenames.

Frame's pre-boot SSH unlock accepts the mair Secretive key and the shared
YubiKey identity used from mmini. SSH authentication starts the restricted disk
unlock command; the disk passphrase is still required.

Home builds use separate root-only software keys and an untrusted `nix-ssh`
account. The old operator `id_ed25519` public keys no longer authorize home
logins. See [builder access](../../../common/_mixins/builders/README.md) for the
staged rollout and store-signing policy before retiring their local files.
Community builders use the separate `nix-community-builders` key.
