# Native macOS provisioning on mmini

This follow-up tests installing macOS from an Apple restore image and reaching
SSH through Apple's native first-boot provisioning API. It complements the
[prepared-image experiment](README.md).

## Environment and inputs

Checked on 2026-10-31:

- Host: `mmini`, macOS 27.2, build 26B123, Apple silicon.
- Resources before the experiment: 32 GiB RAM, 10 CPUs, no swap in use, about
  523 GiB free disk. The existing QEMU Linux builder remains separate.
- Host account: `ihrachyshka`, UID 501. Commands use normal SSH to `mmini`.
- Tools: Tart 2.37.0 and sshpass 1.10 from this checkout's locked unstable
  nixpkgs, without profile installation.
- Experiment directory: `/private/tmp/macos-vm-native-c810` on `mmini`.
- Guest disk: 50 GB logical capacity, using Tart's default raw format.
- Restore image: macOS 27.2, build 26B123, downloaded directly from Apple.

The fixed restore URL comes from the upstream
[macOS 27 image template](https://github.com/cirruslabs/macos-image-templates/blob/main/templates/vanilla-golden-gate.pkr.hcl).
Apple's response advertises 25,595,669,503 bytes and this SHA-256. The completed
download's independently calculated checksum matches:

```text
6613b34e8589db2202a01ec37a2648afb141ece13428175183f8f3e38438534f
```

## Restore

With Tart available in a temporary Nix shell on `mmini`:

```sh
export TART_HOME=/private/tmp/macos-vm-native-c810/tart
export TART_NO_AUTO_PRUNE=1

restore_url=https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/UniversalMac_27.2_26B123_Restore.ipsw
tart create --from-ipsw "$restore_url" --disk-size 50 macos-27-native
```

Tart downloads and caches the restore file, constructs compatible virtual
hardware, and invokes `VZMacOSInstaller`. Its installer selects at least four
CPUs. The restored guest must receive provisioning options on its first normal
boot; an ordinary boot without them would consume that opportunity.

## First attempt: host keychain blocks installation

The download completed, but `VZMacOSInstaller` failed at 0% with “The virtual
machine failed to start.” The host's unified log records the failing operation:

```text
SecKeyCreateRandomKey_ios failed
NSOSStatusErrorDomain Code=-25308 "Failed to generate keypair"
errSecInteractionNotAllowed: Interaction is not allowed with the Security Server.
```

The console owner was `root`, indicating that no user had logged into the
desktop. A login keychain existed, but that alone does not establish that it
was unlocked. These errors match Tart's documented
[headless-host keychain requirement](https://tart.run/faq/#headless-machines).
The framework failure is established; whether unlocking the existing keychain
is sufficient still requires a retry.

The host user can log in through Screen Sharing, or unlock the existing keychain
interactively from their own terminal:

```sh
ssh -t mmini 'security unlock-keychain ~/Library/Keychains/login.keychain-db'
```

No keychain password belongs in this checkout. Host login settings and the
existing keychain remain unchanged. The failed VM bundle was removed by Tart;
the verified IPSW remains cached for a retry without another download.

## Planned native first boot

The planned account is `vmadmin`, distinct from the host account. A generated
temporary password stays in a mode-0600 file within the experiment directory.
Tart receives it in `--provisioning-opts`; this interface exposes the temporary
value in the host process arguments while the VM is running.

The provisioning options request account creation and Remote Login. Guest
automatic login is disabled. No Screen Sharing, Gatekeeper changes, host
directory mounts or SSH-agent forwarding are part of this test.

Native provisioning does not promise the passwordless sudo setting present in
the third-party image. Verify the created account and its sudo policy after
SSH succeeds, then use guest administration credentials for shutdown.

## Checks

The runtime checks are installation, native first-boot provisioning,
authenticated SSH, guest version and resources, administrative access,
outbound HTTPS, and shutdown. A DHCP address or open SSH port alone does not
count as a successful bootstrap.

These guest checks remain pending: the first attempt failed before macOS was
installed. No experimental VM is running, and the QEMU builder was left running.
