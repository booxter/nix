# OpenPGP devices

Public keys live here; device serials and fingerprints are recorded in
[the YubiKey inventory](../yubikeys.nix). Never commit PINs, private keys, or
revocation certificates.

## Home laptop

`home.laptop` is the YubiKey 5C Nano attached to `mair`, serial `38418581`.
Its OpenPGP keys were generated on-device without an off-card encryption-key
backup. Signing and authentication use Ed25519; encryption uses cv25519.
The keys have no expiration. Touch is enabled for all three operations using
the changeable `on` policy, and the USB OTP application is disabled.

Mair imports the public key and makes `pass` prefer it through
`PASSWORD_STORE_GPG_OPTS`. This is a preference, not a requirement: other
available secret keys can still decrypt entries if the Nano cannot.

The password store's `.gpg-id` remains the recipient policy. It currently
retains the old software-key recipient for Android. Add and verify the future
NFC key before removing that recipient. Public keys for every recipient must
be available on clients that write entries.

An isolated keyring containing only this public key and its card references
successfully decrypted a migrated entry with a physical touch. If two GnuPG
homes compete for the card, stop their `scdaemon` processes before retrying.

Keep the revocation certificate and a recovery method outside the password
store. Git backs up encrypted entries, not hardware private keys. Re-encryption
changes the current files; old Git revisions still require their old recipients.
