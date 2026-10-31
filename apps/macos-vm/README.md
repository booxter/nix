# Local macOS VMs

Run from a checkout on an Apple silicon Mac running macOS 27 or newer:

```sh
nix run .#vm -- macos
nix run .#vm -- --gui macos
```

The command runs locally. For example, use a checkout on `mmini` through normal
SSH. The `macos` target creates a plain macOS guest with 4 CPUs, 4 GiB RAM and a
50 GB disk, multi-user Nix, and flakes enabled. It does not yet apply a Darwin
host configuration.
Existing NixOS host targets keep their previous behavior.

On first use, the runner downloads and verifies the pinned Apple restore image,
installs macOS, creates `vmadmin` through native provisioning, installs a
dedicated SSH public key, and shuts down the macOS base. It clones that base to
install Nix, then verifies a fresh daemon build over SSH before and after a
cold restart. Only after those checks and a clean shutdown does it cache the
Nix base. A final clone becomes the current checkout's working VM. Later runs
resume that checkout's working disk.

The macOS and Nix bases are cached separately. Updating or retrying Nix
preparation reuses the macOS base without another restore. Both bases are
shared between checkouts; working disks remain separate.

The terminal prints an SSH command after authenticated access and the Nix
daemon are ready:

```text
Ready: ssh -F /path/to/instance/ssh_config macos-vm
```

Run it in another terminal on the VM host. The generated SSH configuration uses
dedicated credentials and host-key storage. No host directories or SSH agent are
shared with the guest. `--gui` also opens the guest display.

`vmadmin` is an administrator; sudo requires its generated password. The host
file `credentials/password`, beside the printed `ssh_config`, holds it with
mode 0600. The runner uses that password for shutdown. Changing the guest's
password or disabling SSH prevents this clean shutdown path.

Ctrl-C requests an in-guest shutdown and waits for Tart to exit. If the guest
cannot shut down, the runner reports the failure and stops the VM process. The
working disk remains available on the next run. SIGTERM and SIGHUP also request
shutdown; a forced kill cannot run cleanup.

To discard that checkout's guest changes and clone a fresh base:

```sh
nix run .#vm -- --reset macos
```

Reset keeps the cached restore image and both prepared bases. It refuses to
reset an active VM. An interrupted instance preparation requires an explicit reset;
interrupted base preparation is retried automatically.

VMs created before Nix preparation was added continue to boot their existing
disks. To get Nix from the new base, use `--reset macos`; this discards that
working VM's files and changes.

## Storage and prerequisites

State lives under `${XDG_STATE_HOME:-$HOME/.local/state}/fleet-vm/macos`:

- `images/`: verified IPSWs and resumable partial downloads.
- `bases/`: macOS-base metadata and private bootstrap credentials.
- `nix-bases/`: metadata and credentials for bases with verified Nix installations.
- `instances/`: credentials and SSH configuration for each checkout/worktree.
- `tart/`: macOS bases, Nix bases, and working VM disks.
- `locks/`: exclusive base-preparation and instance-session locks.

Bases are shared between worktrees. Working disks are separate, keyed by the
canonical checkout path. Use `XDG_STATE_HOME` to choose a different state root;
keep it on APFS for fast copy-on-write cloning. Temporary directories are useful
for tests but do not provide durable VM storage.

The first restore image is about 25.6 GB; the macOS base occupies about
27 GB. Nix bases and working clones initially share disk blocks, then grow as
they change. Leave room for the base, Nix installation, and guest writes.
The runner disables Tart's
automatic cache pruning within its dedicated state directory.

Virtualization.framework needs the host's login keychain unlocked. If startup
fails with `errSecInteractionNotAllowed` or `Failed to generate keypair`, log in
to the host or unlock its existing keychain from your own terminal:

```sh
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

No host sudo is needed for this workflow. The runner uses NAT networking and
native first-boot provisioning, both verified in the
[`mmini` experiment](../../experiments/macos-vm/mmini.md).

## Maintaining the base recipe

[image.nix](image.nix) pins the Apple URL, version, build and SHA-256. Update
them together when selecting a new release, and verify a fresh restore through
SSH. Increment `recipe` when changing bootstrap behavior. Both the image digest
and recipe version identify a base. An existing working VM keeps its current OS
until explicitly reset; a pin update never replaces its disk automatically.

[installer.nix](installer.nix) pins the standalone
[NixOS installer](https://github.com/NixOS/nix-installer), including its embedded
Nix release. It is tracked by the repository's `update-packages` machinery.
The bootstrap recipe in [default.nix](default.nix) covers installation and
verification behavior. Changing either creates a new Nix base from the same
macOS base, leaving existing working disks intact. Failed Nix preparation is
discarded and retried from that macOS base on the next invocation.

Tart comes from the flake's locked unstable nixpkgs input. The bootstrap password
is passed through Tart's provisioning option during initial setup and is
therefore briefly visible in that process's arguments. Credentials stay outside
the Nix store and repository.

The Rust `vm` entry point selects the NixOS runner or this Python backend. The
backend's package checks exercise persistence, reset, worktree isolation,
preparation failures, Nix cache reuse, restart verification, locking, SSH
configuration, cancellation and shutdown.
Nix builds run strict mypy, Ruff and pytest with an 85% coverage floor on both
Darwin and Linux; running a macOS guest requires the supported Darwin host.
