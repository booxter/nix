# Native macOS provisioning on mmini

Installing macOS from an Apple restore image and reaching SSH through Apple's
native first-boot provisioning API succeeded on `mmini`. A clone of the stopped
base also booted and accepted SSH without provisioning options. This complements
the [prepared-image experiment](README.md).

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
- Guest resources: 4 CPUs and 4 GiB RAM, selected by Tart during installation.
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
After the user unlocked the keychain, the same restore succeeded using the
cached IPSW. The console owner remained `root` throughout installation, first
boot and clone reuse. All VM commands ran over SSH.

The host user can log in through Screen Sharing, or unlock the existing keychain
interactively from their own terminal:

```sh
ssh -t mmini 'security unlock-keychain ~/Library/Keychains/login.keychain-db'
```

No keychain password belongs in this checkout. No host login settings or
keychain configuration were changed. Unlocking the existing keychain was the
only host preparation after the failed attempt. Operation after another host
reboot or keychain lock remains untested.

## Native first boot

The account is `vmadmin`, distinct from the host account. A generated temporary
password stays in a mode-0600 file within the experiment directory. Run these
commands on `mmini`, with the same tool shell and environment as above, only
for a newly restored base:

```sh
set -eu
umask 077
password_file=/private/tmp/macos-vm-native-c810/bootstrap-password
test ! -e "$password_file"
openssl rand -hex -out "$password_file" 24

provisioning_opts='fullName=VM Administrator,username=vmadmin'
provisioning_opts="$provisioning_opts,password=$(cat "$password_file")"
provisioning_opts="$provisioning_opts,logsInAutomatically=false,enablesRemoteLogin=true"
tart run --no-graphics --no-audio --no-clipboard \
  --provisioning-opts="$provisioning_opts" macos-27-native
```

Tart receives the password in `--provisioning-opts`; this interface exposes the
temporary value in the host process arguments while the VM is running.

The provisioning options request account creation and Remote Login. Guest
automatic login is disabled. No Screen Sharing, Gatekeeper changes, host
directory mounts or SSH-agent forwarding are part of this test.

In a second shell on `mmini`, resolve the address and verify authenticated SSH:

```sh
password_file=/private/tmp/macos-vm-native-c810/bootstrap-password
guest_address=$(tart ip --wait 45 macos-27-native)
SSH_ASKPASS_REQUIRE=never sshpass -f "$password_file" ssh -F /dev/null \
  -o "HostName=$guest_address" -o HostKeyAlias=macos-27-native \
  -o IdentityAgent=none -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1 \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/private/tmp/macos-vm-native-c810/known_hosts \
  -o ConnectTimeout=10 \
  vmadmin@macos-27-native 'sw_vers; uname -m; id'
```

The account is an administrator, but `sudo -n true` fails because a password
is required. Supplying the generated password to `sudo -S -p '' id -u`
returned `0`; `sudo -l` permits `(ALL) ALL`. Unlike the prepared Cirrus image,
native provisioning leaves sudo password-protected.

For shutdown, use the same SSH options with the remote command
`sudo -S -p '' /sbin/shutdown -h now`, supplying stdin from `"$password_file"`.
Pass the password for each privileged invocation instead of relying on a sudo
authentication timestamp. Wait for `tart run` to exit before cloning the base.

## Results and reuse

| Check | Observed result |
| --- | --- |
| Apple IPSW restore | Completed after unlocking the host keychain. |
| First boot | Created `vmadmin`, enabled SSH; automatic login disabled. |
| Guest identity | macOS 27.2, build 26B123, ARM64; 4 CPUs and 4 GiB RAM. |
| Administrative access | Password-authenticated sudo succeeded. |
| Network | Default NAT; guest HTTPS to the Nix cache returned HTTP 200. |
| Shutdown | In-guest shutdown; Tart reported success and exited. |
| Cached clone | 0.01 seconds, with no download or reinstall. |
| Clone boot | SSH worked without provisioning options. |
| Host session | SSH as UID 501, no host sudo, console owner still `root`. |
| Resources | One experimental guest at a time; host swap remained unused. |

The clone timing is a single observation, not a benchmark. Reuse was tested with:

```sh
tart clone macos-27-native macos-27-reuse
tart run --no-graphics --no-audio --no-clipboard macos-27-reuse
```

The clone accepted SSH as `vmadmin`, reported the same guest version, and shut
down cleanly using its administrator password. Provisioning is a one-time base
construction step; ordinary boots and clones do not repeat it.

The disposable `macos-27-reuse` clone was deleted after shutdown. The stopped
`macos-27-native` base, cached IPSW, private bootstrap password and SSH host-key
file remain under `/private/tmp/macos-vm-native-c810` on `mmini`. Tart reports
27 GB for the base; the IPSW download is another 25.6 GB. Temporary storage is
appropriate for this experiment, not a durable cache.

No experimental VM is running. The existing QEMU Linux builder remained running,
and the host still had about 473 GiB free disk at the end. Nix installation and
nix-darwin activation inside the guest remain subsequent milestones.
