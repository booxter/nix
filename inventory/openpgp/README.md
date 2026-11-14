# OpenPGP password store

Public certificates live here; serials and fingerprints belong in the
[YubiKey inventory](../yubikeys.nix). Never commit private keys, PINs, or
revocation certificates.

The home password store uses three hardware recipients:

- `home.laptop`: mair.
- `home.main`: shared between frame and mmini.
- `home.nfc`: Android Password Store with OpenKeychain.

Keys are generated on-device, use Ed25519/cv25519, and have no expiration.
Touch is required; Yubico OTP is disabled. The store's `.gpg-id` controls
recipients, and every writer needs all recipient public certificates.

Set `host.hm.pass.yubikey` to the realm's inventory name. This imports the
realm's public certificates and sets a decryption preference, not a restriction.
The default idle timeout is 15 minutes, configurable with
`host.hm.pass.idleTimeout`. The next pass operation after expiry resets GPG
authorization; direct GPG calls bypass this policy.

Desktop PIN prompts are graphical. SketchyBar shows pass decryption activity;
other OpenPGP clients are outside its scope.

## Android

Import all three public certificates. Use **Manage my keys → Use security
token** to associate the NFC key, then allow only that key under
**Apps → Password Store → Allowed Keys**.

## Recovery

Keep revocation certificates and recovery material outside the store.
Git backs up ciphertext, not hardware private keys. Changing recipients does
not change Git history: keep retired keys under `~/keys-backup/openpgp/`
for older revisions, outside the active keyring.
