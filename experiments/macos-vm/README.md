# macOS VM exploration

This experiment evaluates a local, noninteractive counterpart to `nix run .#vm`.
The first milestone is a booted macOS guest reachable over SSH. Installing Nix
and applying a nix-darwin configuration are subsequent milestones.

## Options

Research checked on 2026-10-31 against the current host (Apple silicon,
macOS 26.5.1) and this checkout's pinned unstable nixpkgs.

| Option | Noninteractive path | Assessment |
| --- | --- | --- |
| [Tart](https://tart.run/quick-start/) | Clone a prepared image, start with `--no-graphics`, discover its address with `tart ip`, then SSH. | Best first experiment. Already packaged in pinned nixpkgs as 2.37.0. |
| [Lume](https://github.com/trycua/cua/tree/lume-v0.6.1/libs/lume) | Restore an Apple IPSW and use offline unattended setup to create an account and enable SSH. | Promising route to our own base image on this host; not packaged in the inspected nixpkgs. |
| [UTM](https://docs.getutm.app/scripting/scripting/) | `utmctl` controls existing VMs through the application's scripting interface. | Useful desktop tool; a less direct dependency for a small checkout-run CLI. |
| [VirtualBuddy](https://github.com/insidegui/VirtualBuddy) | GUI for installing and cloning macOS guests. | Useful for interactive debugging; not the first choice for this CLI workflow. |
| [vfkit](https://github.com/crc-org/vfkit/blob/main/doc/usage.md) | Starts a prepared macOS disk with its hardware model, machine identifier and auxiliary storage. | Lower-level building block; still needs an installer and account bootstrap. |
| [vzvm](https://github.com/applicative-systems/vzvm) | Boots Linux from a kernel and initrd; the NixOS integration forwards SSH over vsock. | Good Nix integration reference, not a macOS guest runner. |
| [Apple Virtualization.framework](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon) | Provides restore, VM configuration, boot and device APIs. | A custom runner is possible, but duplicates existing lifecycle tooling. |

Virtualization.framework supplies the macOS guest platform and restoration
machinery. The lower-level
[Hypervisor framework](https://developer.apple.com/documentation/hypervisor)
does not itself replace that guest setup. There is no demonstrated requirement
for a new hypervisor here.

## Installation is separate from first boot setup

Restoring an IPSW installs macOS, but an unconfigured guest still needs an
account and Remote Login. On this host, the practical choices are:

- Use an already prepared image. The Cirrus Labs
  [Sequoia template](https://github.com/cirruslabs/macos-image-templates/blob/main/templates/vanilla-sequoia.pkr.hcl)
  automates Setup Assistant with timed keyboard and UI actions when building
  that image. Consumers do not repeat those actions. Its `vanilla` name does
  not imply untouched Apple defaults: the template enables passwordless sudo,
  changes login/security settings, and installs command-line tools.
- Build our own image using Lume's
  [offline setup](https://cua.ai/docs/lume/concepts/how-lume-works).
  It installs, briefly boots and stops, modifies the mounted guest Data volume,
  then boots again and checks SSH. Its Tahoe preset is upstream's verified
  path; the Sequoia preset has a documented first-display Accessibility issue.
  This path has not been exercised locally.

Apple now offers
[VZMacGuestProvisioningOptions](https://developer.apple.com/documentation/virtualization/vzmacguestprovisioningoptions),
which creates the initial account and can enable SSH. It requires macOS 27 on
both host and guest and only applies on the first boot after restore. Tart
2.37.0 exposes it as `--provisioning-opts`; UTM exposes corresponding provisioning
flags. It cannot solve first-boot setup on the current 26.5.1 host.

A host upgrade to macOS 27 is an acceptable design option. That makes Tart
with an Apple IPSW and native first-boot provisioning the preferred direction
for our own base. The existing host does not need an upgrade to prove headless
boot, SSH and clone reuse with a prepared image.

The macOS 27 experiment uses:

```sh
tart create --from-ipsw /path/to/pinned-macos-27.ipsw macos-base
tart set macos-base --cpu 4 --memory 4096

provisioning_opts='fullName=VM Administrator,username=vmadmin'
provisioning_opts="$provisioning_opts,password=temporary-bootstrap-password"
provisioning_opts="$provisioning_opts,logsInAutomatically=false,enablesRemoteLogin=true"
tart run --no-graphics --no-audio --no-clipboard \
  --provisioning-opts="$provisioning_opts" \
  macos-base
```

The [follow-up on `mmini`](mmini.md) verified this path on its existing macOS
27.2 installation: Apple IPSW restore, native provisioning, authenticated SSH,
password-authenticated sudo, clean shutdown and clone reuse all succeeded.
The host login keychain had to be unlocked; all VM commands ran over SSH
without guest UI interaction. Use a generated temporary password; Tart's option
exposes it in the process arguments. SSH is sufficient for subsequent bootstrap
and does not require enabling Screen Sharing or disabling Gatekeeper. The upstream
[macOS 27 template](https://github.com/cirruslabs/macos-image-templates/blob/main/templates/vanilla-golden-gate.pkr.hcl)
uses the same provisioning API but includes additional UI customization that
this narrower workflow does not need.

## Reproduce the Tart experiment

Run from this checkout. Tools come from its locked nixpkgs input and are not
installed into a profile:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure --inputs-from . \
  nixpkgs-unstable#tart nixpkgs-unstable#sshpass

export TART_HOME=/private/tmp/macos-vm-poc-c810/tart
export TART_NO_AUTO_PRUNE=1
```

Use a dedicated directory on APFS. The selected image is a 23.7 GB compressed
download with a 50 GB logical disk. Check available disk and memory before
running it, including resources used by the existing Linux builder. Automatic
pruning is disabled so the experiment cannot evict other cached images.

The fixed digest below was resolved from the public Sequoia vanilla image. It
is an experiment input, not a maintained production image pin:

```sh
image=ghcr.io/cirruslabs/macos-sequoia-vanilla@sha256:57a83b1b52f928f5b11b0963927178fd6c4cac52c315279f227c27cc5ab81587
tart clone --concurrency 2 "$image" macos-poc
tart set macos-poc --cpu 2 --memory 4096
tart run --no-graphics --no-audio --no-clipboard macos-poc
```

`tart run` stays in the foreground. In another shell with the same tools and
`TART_HOME`, resolve the guest and connect using a distinct SSH alias and host
key file. The image's published bootstrap credentials are `admin` / `admin`.
No host directories or SSH agent need to be shared with the guest.

```sh
guest_address=$(tart ip --wait 120 macos-poc)
SSH_ASKPASS_REQUIRE=never sshpass -p admin ssh -F /dev/null \
  -o "HostName=$guest_address" \
  -o IdentityAgent=none -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$TART_HOME/known_hosts" \
  admin@macos-poc 'sw_vers; uname -m; id'
```

An address lease alone is not an SSH readiness check; retry a refused
connection while the guest finishes booting. Default networking is NAT, not
a bridged interface. The explicit `SSH_ASKPASS_REQUIRE=never` lets `sshpass`
supply terminal input: this repository's agent environment otherwise forces
the GUI password helper, which caused the initial authentication attempt to
fail. The override applies only to this bootstrap command.

The known bootstrap password is suitable only for this disposable experiment;
a reusable bootstrap should install a per-instance public key and replace
password authentication before applying configuration.

Stop the VM when finished:

```sh
tart stop macos-poc
tart list
```

For a base that will be cloned, shut macOS down over SSH with
`sudo -n /sbin/shutdown -h now` and wait for Tart to exit. The experiment also
tested `tart stop` as the lifecycle stop command.

## Local results

The prepared-image path was exercised on 2026-10-31:

| Check | Observed result |
| --- | --- |
| Temporary tools | Tart 2.37.0 and sshpass 1.10 from locked nixpkgs. |
| Headless boot | Two guests, each with 2 CPUs / 4096 MiB; one at a time. |
| Guest identity | macOS 15.7.7 (24G720), ARM64. |
| Access | SSH as `admin`; `sudo -n true` succeeded. |
| Network | Guest HTTPS to the [Nix cache](https://cache.nixos.org/nix-cache-info) returned HTTP 200. |
| Cached clone | 0.02 seconds, no download, roughly 1 MiB before boot. |
| Isolation | First guest's marker absent in fresh clone of cached image. |
| Stop | `tart stop` and in-guest shutdown both ended the VM process. |
| Native provisioning | Rejected with the explicit macOS 27 requirement. |

The clone timing and space measurement are single observations, not a
benchmark. Both guests used `--no-graphics` without GUI interaction. For the
second guest, Tart exited successfully after macOS shutdown and reported that
the guest had stopped the virtual machine.

The first SSH attempt used the forced GUI password helper inherited from the
agent environment. A diagnostic trace showed `read_passphrase: requested to
askpass`; the per-command override above allowed password delivery. The fresh
clone also rejected one early authentication attempt with that override already
set. Subsequent attempts with unchanged credentials succeeded with both system
OpenSSH and Nix OpenSSH. That second transient failure's cause remains unproven;
the inspected guest log did not establish it. A future runner needs a bounded
authenticated SSH readiness check, not merely an address or an open port.

The additional test clone was removed. The stopped `macos-poc` VM and cached
image remain under `/private/tmp/macos-vm-poc-c810/tart` for reuse. The cached
image occupies about 30 GB of allocated blocks; clones share most of those
blocks, so adding their reported sizes overstates physical usage. Temporary
storage is suitable for this experiment, not a durable base-image cache.
To resume the retained VM, enter the Nix shell above, set `TART_HOME`, and run
the `tart run` command; skip cloning over the existing name.

No Nix installation, nix-darwin activation, host upgrade or deployment was
performed. The existing QEMU builder was left running.

## Reusing a base

Tart's ordinary clone uses APFS copy-on-write. Keep the prepared base stopped
and clone it for each experiment; the clone consumes additional blocks as it
changes. Preserve the entire VM bundle, including configuration and NVRAM,
rather than copying only `disk.img`. Cold, cleanly shut down bases are simpler
than saved RAM state for configuration testing.

The newer `tart clone --stacked` mode is a different mechanism. Its
[DiskImageKit implementation](https://github.com/openai/tart/blob/2.37.0/Sources/tart/DiskImageStack.swift)
requires macOS 27, so ordinary APFS clones are the relevant option here.

The Linux builder's
[NixOS profile](https://github.com/NixOS/nixpkgs/blob/885ba4d038f1/nixos/modules/profiles/nix-builder-vz-vm.nix)
is a useful model for generated configuration and loopback access. Its
`systemd-ssh-generator` guest service is Linux-specific, so its SSH plumbing
cannot simply be reused as a macOS bootstrap.

## Designs to choose from

1. **Tart with a prepared base, for immediate use.** Pin an image digest, cache
   the stopped base, clone it, boot, wait for SSH, and provision the clone. This
   is the smallest route to a useful macOS test VM today. It makes the upstream
   image and its bootstrap choices part of the trust boundary.
2. **Tart with a locally built base on macOS 27, preferred.** Cache an Apple
   IPSW and a base identified by the restore image and bootstrap recipe. Use
   the native provisioning API to reach SSH. If retaining macOS 26 matters,
   evaluate Lume's offline setup as an alternative. This gives control of the
   initial account and settings, at the cost of maintaining and testing image
   construction. Interchange between Lume and Tart bundles must be verified
   before combining them.
3. **A custom Virtualization.framework runner.** Generate a small VM manifest
   with Nix and implement installation/lifecycle in Swift. It still needs the
   same base preparation, persistent VM identity and access path. Consider this
   only if an existing runner has a concrete limitation that blocks the task.

For either of the first two designs, Nix should build tools and configuration
closures while writable VM state remains outside the Nix store. A later
checkout-run app can own cloning, readiness timeouts, shutdown and a stable SSH
alias. Base reuse should depend on the OS image and bootstrap recipe, not on
every change to the target nix-darwin configuration.

After SSH is reliable, bootstrap Nix once in a base, then apply a VM-specific
nix-darwin configuration to a clone. The current Darwin configuration includes
the Linux builder, machine identity, secrets and host services, so reusing a
physical host configuration requires an explicit VM variant first. The current
`vm` app and its Nix runner only select `nixosConfigurations`.

Tart's packaged release uses
[FSL-1.1-ALv2](https://github.com/openai/tart/blob/2.37.0/LICENSE).
Lume's inspected release uses the
[MIT license](https://github.com/trycua/cua/blob/lume-v0.6.1/LICENSE.md).
Keep that distinction in the dependency comparison, especially if this grows
beyond a personal local tool.

## Remaining checks

- Test Nix installation and activation inside a disposable guest.
- Exercise operation after host logout/reboot. Tart documents an
  [unlocked login keychain requirement](https://tart.run/faq/#headless-machines)
  on newer macOS hosts; a headless guest and a headless host are different cases.
