# Sudo authentication

Sudo accepts hardware SSH keys from the destination realm's
[`sshKeys.sudo` allowlist](../../../inventory/ssh/default.nix).
Forwarding an agent does not grant cross-realm access. The operator cannot
modify the installed allowlist.

Approval happens on the originating machine through Touch ID or a YubiKey.
Password authentication remains available; configured Macs also retain local
Touch ID. `sudo -n` can request hardware approval without reading a password.

Approval is cached for 15 minutes across the operator's sessions on that
destination. Use `sudo -K` to clear it. If using agent-backed sudo before an SSH
connection has loaded the YubiKey handles, load them with `ssh-add`.

SSH certificates authorize login, not sudo. SOPS uses a separate
[forwarded key service](../../../apps/sops/README.md#hardware-authentication-over-ssh).
