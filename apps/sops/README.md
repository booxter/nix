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

Public age handles come from [inventory](../../inventory/yubikeys.nix):
frame and mmini use `home.main`; the work laptop uses `work.main` and
`work.laptop`. Private keys stay on the devices. Bootstrap adds all configured
recipients; preserve each handle's `Recipient` comment when combining files.

Decryption requires the PIV PIN and touch. The PIV PIN is separate from the
FIDO2 PIN used for SSH.

## Hardware authentication over SSH

Operator machines run a SOPS key service in their local desktop session. Normal
`ssh <machine>` connections within the same realm forward that service, so remote
`sops` and repository secret helpers ask for approval on the originating machine.
Onward connections retain the original service. Both ends must have forwarding
configured. Explicit `ssh -F <config>` and unwrapped OpenSSH calls do not get
automatic SOPS forwarding.

Forwarded operations fail if the originating service is unavailable; they do
not fall back to the destination's hardware. Disconnecting closes access.
Private keys stay at the origin, but the destination receives the file's data
key and can read its contents.
Host activation continues to use the host's own sops-nix identity.
