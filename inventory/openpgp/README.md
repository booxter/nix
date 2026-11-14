# OpenPGP devices

Public keys live here; device serials and fingerprints are recorded in
[the YubiKey inventory](../yubikeys.nix). Never commit PINs, private keys, or
revocation certificates.

Set `host.hm.pass.yubikey` to the device's inventory name within the host's realm:
mair uses `laptop`; frame and mmini use `main`. This imports the realm's OpenPGP
public certificates, prefers the selected key for decryption, and defaults to a
15-minute idle timeout. The shared device can move between frame and mmini;
each host uses the same on-card keys.

## Home laptop

`home.laptop` is the YubiKey 5C Nano attached to `mair`, serial `38418581`.
Its OpenPGP keys were generated on-device without an off-card encryption-key
backup. Signing and authentication use Ed25519; encryption uses cv25519.
The keys have no expiration. Touch is enabled for all three operations using
the changeable `on` policy, and the USB OTP application is disabled.

Mair imports the home realm's public keys and makes `pass` prefer its Nano through
`PASSWORD_STORE_GPG_OPTS`. This is a preference, not a requirement: other
available secret keys can still decrypt entries if the Nano cannot.

On mair, `pass` resets `scdaemon` and `gpg-agent` before its next secret
operation after 15 minutes of inactivity. Successful operations restart
the timer when they finish. Plain `pass`/`pass ls`, find, help, and version
commands bypass it. Listings with arguments and Git commands participate:
`pass ls NAME` can decrypt an entry, as can `pass git diff` through textconv.
The first use also resets authorization. Concurrent secret operations wait for
one another, so an active read or edit cannot be interrupted by another reset.
State contains only a timestamp per GnuPG home under
`$XDG_STATE_HOME/pass-idle` (default `~/.local/state/pass-idle`).

This is enforced by the wrapper when invoked, not by a background timer or the
YubiKey itself. Direct `gpg` use bypasses it, and resetting the shared agent
also clears other GnuPG authorization for that home. GnuPG's ordinary cache
TTLs do not expire its YubiKey PIN cache. A reset failure stops the operation.
Override `host.hm.pass.idleTimeout` to change this policy for a host.

GnuPG prompts use `pinentry-mac` on macOS and `pinentry-qt` on Linux desktops
(including frame's Hyprland session). Headless Linux hosts use `pinentry-tty`.
These are separate from SSH's `SSH_ASKPASS` helpers. A Linux graphical prompt
requires a running desktop session. Where Linux already runs `pcscd` for age,
GPG uses that service through `disable-ccid`; its direct USB driver otherwise
failed to open frame's readers without falling back to PC/SC.

On macOS with SketchyBar, pass shows the shared yellow request indicator during
each GPG decryption, including PIN and touch waits. It clears when GPG exits,
before an editor opens. The label is `OpenPGP`; it describes the operation,
including software-key fallback. SSH uses the same display helper with its key
names. Direct GPG calls and other OpenPGP clients are outside this indicator's
scope.

The password store's `.gpg-id` remains the recipient policy. Its recipients are
`home.laptop`, `home.main`, and `home.nfc`; the old software key is no longer a
recipient for current entries. Android decryption with the NFC key is verified.
Public keys for every recipient must be available on clients that write entries.
After retiring the software recipient, a rewritten store entry successfully
decrypted with the shared Nano on frame and the laptop Nano on mair. All current
entries were checked for exactly these three hardware recipients.

An isolated keyring containing only this public key and its card references
successfully decrypted a migrated entry with a physical touch. If two GnuPG
homes compete for the card, stop their `scdaemon` processes before retrying.

Keep the revocation certificate and a recovery method outside the password
store. Git backs up encrypted entries, not hardware private keys. Re-encryption
changes the current files; old Git revisions still require their old recipients.

## Home main

`home.main` is the YubiKey 5C Nano, serial `35640926`, shared between frame and
mmini. Its existing SSH and age credentials are unchanged. OpenPGP signing and
authentication use Ed25519; encryption uses cv25519. The keys were generated
on-device without an off-card encryption-key backup and have no expiration.
Touch is enabled for all three operations using the changeable `on` policy.
The USB OTP application was already disabled.

Messages encrypted only to this key successfully decrypted through `pass` on
both mmini and frame, with their native graphical PIN prompts and physical
touch. Both the home and work YubiKeys were connected during these tests.

## Home NFC

`home.nfc` is the YubiKey 5C NFC, serial `31341726`, intended for Android
Password Store with OpenKeychain. Its applications were reset before provisioning,
and Yubico OTP is disabled over both USB and NFC.

The OpenPGP keys were generated on-device without an off-card encryption-key
backup. Signing and authentication use Ed25519; encryption uses cv25519.
The keys have no expiration. Touch is enabled for all three operations using
the changeable `on` policy. A harmless message encrypted only to this key was
successfully decrypted over USB with touch.

The initial Android client versions are Password Store 1.13.5 and OpenKeychain
6.0.4. The same harmless message was successfully decrypted over NFC in
OpenKeychain. After importing the public key, use **Manage my keys → Use security
token** and scan the YubiKey to associate it with the imported certificate.
Importing the public key alone leaves decryption reporting that no known secret
key is available.

Android Password Store also successfully decrypted a synced store entry over
NFC. To force that path, open **OpenKeychain → Apps → Password Store** and save
**Allowed Keys** with only `pass - NFC 31341726` selected. This restricts the
app's decryption permissions without deleting the old software key; its
permission can be restored there if needed.

Android needs the public certificates for every `.gpg-id` recipient to create
or edit entries. Import `home-laptop.asc`, `home-main.asc`, and `home-nfc.asc`.
The laptop and shared home public certificates appear under Ihar rather than
**My keys**, which is expected. No Nano pairing is needed for encryption.
Missing recipient certificates cause OpenKeychain to report
`Missing key for encryption: %s`. Keep the app's **Allowed Keys** limited to the
NFC key for decryption.

An Android-created test entry preserved the configured recipient list and
successfully decrypted on mair in an isolated keyring containing only the
Nano's public certificate and card references. This verifies Android writes
preserve access for the laptop as well as NFC decryption on the phone.
