# SOPS tools

Secrets are managed via sops-nix, with one encrypted YAML
per host under `secrets/<realm>/`. The helpers use the enclosing Git checkout,
so its secret files must match the installed tools' realm layout.

## Commands

```sh
# Bootstrap a host secret
nix run .#sops-bootstrap -- beast
nix run .#sops-bootstrap -- beast --user root

# Current host (detected from hostname)
nix run .#sops-cat
nix run .#sops-edit
nix run .#sops-update

# Explicit host
nix run .#sops-cat -- mair
nix run .#sops-edit -- mair
nix run .#sops-update -- mair
printf %s "$attic_token" | nix run .#sops-set -- --realm home --all attic/token
nix run .#sops-unset -- --realm home --all obsolete/token
nix run .#sops-pass -- beast root
nix run .#sops-pass -- --gen gw root
nix run .#sops-pass -- --gen gw both
nix run .#sops-pass -- beast ihrachyshka

# Copy one section between host secrets
nix run .#sops-copy -- mair prx1-lab attic
```

Run `sops-update` when a host secret should receive missing template keys.
`sops-edit` only opens the selected secret for editing.
`sops-set --all` and `sops-unset --all` update every host secret in the selected
realm and report completed and remaining hosts if an operation fails partway
through.

## Operator YubiKeys

Frame and mmini use the `home.main` public age handle from
[inventory](../../inventory/yubikeys.nix). Activation supplies it from the Nix
store, so these hosts do not need a manually provisioned `yubi-nix.txt` file.
The handle refers to the existing YubiKey identity; recipients do not change.

The work laptop's operator identity file combines the public handles for
`work.main` and `work.laptop` from [inventory](../../inventory/yubikeys.nix).
These handles identify PIV slots; private keys remain on the devices. The local
SOPS key service uses this file, and bootstrap adds every recipient listed in it
to the host's policy. Keep each handle's `Recipient` comment when combining files.

Both keys require their PIV PIN and a touch for decryption. The PIV PIN is
separate from the FIDO2 PIN used for SSH. Existing work secrets also retain the
Secure Enclave recipient for recovery during enrollment.

## Hardware authentication over SSH

Operator machines run a SOPS key service in their local desktop session. Normal
`ssh <machine>` connections within the same realm forward that service, so remote
`sops` and repository secret helpers ask for approval on the originating machine.
For example, `mair` to `frame` uses `mair`'s Touch ID identity; `frame` to `mair`
uses the YubiKey attached to `frame`. An onward SSH connection retains the
original service. Deploy the configuration on both ends before using forwarding.
Explicit `ssh -F <config>` connections use that config without automatic SOPS
forwarding. Programs that invoke unwrapped OpenSSH, such as Git, continue to use
the ordinary SSH config.

Each connection gets its own socket inside a private directory. Forwarded SOPS
operations fail if the originating service is unavailable, rather than trying
the destination's hardware. Disconnecting closes access to the service; sshd
may leave an inactive socket file behind. The hardware private key stays at the
origin, but the destination receives the file's data key and can read its contents.
Host activation continues to use the host's own sops-nix identity.

The [Home Manager module](../../hm/_mixins/security/sops-forwarding.nix)
configures the desktop service and SSH wrapper. The wrapper selects a separate
SSH config after setting its forwarding variables; the ordinary SSH config
must remain usable without them. The [SOPS package](../../pkgs/sops-keyservice)
adds graphical PIN prompts for the service.

To test from an operator desktop, connect to another deployed machine and run
this inside an up-to-date checkout:

```sh
sops-cat --realm home org >/dev/null && echo "Decryption OK"
```

Approval should happen on the originating machine. Repeat in the other direction
from that machine's local desktop to test its hardware identity.
