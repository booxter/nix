# Sudo authentication

NixOS and Darwin sudo accept the hardware SSH keys in
[`sshKeys.sudo`](../../../inventory/ssh/default.nix). The allowlist is installed
under `/etc/sudo/authorized_keys/` and cannot be changed by the operator.

With agent forwarding, `sudo` asks the originating machine's Touch ID or YubiKey
to sign a challenge. NixOS uses its `pam_rssh` module options; Darwin loads the
same module through `sudo_local`, before the existing local authentication
methods. Password authentication remains available, and configured Macs retain
their native Touch ID fallback. `sudo -n` can authenticate through the agent
without reading a password from stdin.

Successful approval is cached for 15 minutes across the operator's sessions on
that destination machine. The cache is shared by the account, including sessions
from different clients. `sudo -K` clears it.

Work machines `nv` and `nvws` use the same hardware approval. On the work laptop,
load the YubiKey handles and forward the agent when connecting:

```sh
ssh-add ~/.ssh/id_ed25519_sk_work_main ~/.ssh/id_ed25519_sk_work_laptop
ssh -A nv
```

After deploying, test from a fresh SSH session:

```sh
sudo -K
sudo -n id -u
```

Approve on the originating machine; the command should print `0`. A second SSH
session to the same destination should run `sudo -n id -u` without another
approval until the cache expires or is cleared.

SSH certificates authenticate login, not sudo. SOPS uses a separate
[forwarded key service](../../../apps/sops/README.md#hardware-authentication-over-ssh).
