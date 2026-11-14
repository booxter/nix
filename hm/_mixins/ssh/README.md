# Operator SSH credentials

Operators sign Git commits and tags with approved hardware identities from
`sshKeys.hardware`. Signing fails when no approved key is available.

Local sessions use the configured agent: nixpkgs OpenSSH for file and YubiKey
credentials, Secretive for Secure Enclave credentials. SSH sessions preserve
the forwarded agent, so approval happens on the originating machine.
YubiKey handles are loaded automatically before ticket connections.
Open a fresh shell after changing agent configuration.

SSH tickets are scoped to their destination and stay out of the agent.
Onward SSH and forwarded-agent sudo use the operator's hardware identity.

Device names, serials, and public keys belong in the
[YubiKey inventory](../../../inventory/yubikeys.nix) and
[SSH inventory](../../../inventory/ssh/default.nix).
Configure handle paths with `host.ssh.credentials.yubikey.identityFiles`.

PIN and touch prompts identify known keys by inventory name. macOS uses native
dialogs and a SketchyBar indicator; Linux graphical sessions use Zenity.
Touch only the intended flashing token. The SSH FIDO2 PIN is separate from
the PIV PIN used for SOPS.

Frame's pre-boot SSH accepts the mair Secretive key and shared home YubiKey.
Login starts the restricted unlock command; the disk passphrase is still needed.

Builds use separate root-only software keys and an untrusted `nix-ssh` account.
See [builder access](../../../common/_mixins/builders/README.md).
