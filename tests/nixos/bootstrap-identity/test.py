# ruff: noqa: F821
# The NixOS test driver supplies the machines and QEMU executable.

import shlex


def install_with_identity():
    controller.succeed("test -x /etc/install-disko && test -d /etc/install-system/bin")
    controller.succeed(
        "install -d -m 0700 /run/extra-files/etc/ssh && "
        "install -m 0600 /etc/host-key-fixture "
        "/run/extra-files/etc/ssh/ssh_host_ed25519_key"
    )
    print(
        controller.succeed(
            "nixos-anywhere --phases disko,install "
            "--extra-files /run/extra-files "
            "--store-paths /etc/install-disko /etc/install-system "
            "--no-substitute-on-destination "
            "-i /root/.ssh/id_ed25519 root@target < /dev/null 2>&1",
            timeout=600,
        )
    )
    controller.succeed("rm -rf /run/extra-files")


def boot_installed_system():
    target.succeed("umount -R /mnt && sync")
    target.shutdown()
    # Boot the installed disk using the same setup as nixos-anywhere's VM tests.
    command = [
        QEMU,
        "-cpu",
        "max",
        "-m",
        "2048",
        "-drive",
        f"file={target.state_dir}/installed.qcow2,id=drive1,if=none,werror=report",
        "-device",
        "virtio-blk-pci,drive=drive1",
        "-netdev",
        "user,id=wan",
        "-device",
        "virtio-net-pci,netdev=wan",
        "-netdev",
        f"vde,id=lan,sock={vlan1.socket_dir}",
        "-device",
        "virtio-net-pci,netdev=lan,mac=52:54:00:12:01:03",
    ]
    machine = create_machine(start_command=shlex.join(command), name="installed")
    driver.machines_qemu.append(machine)
    machine.start()
    return machine


def deploy_uncached_helper():
    controller.succeed(
        "cp -LR /etc/deploy-source /root/source && chmod -R u+w /root/source && "
        "git -C /root/source init && git -C /root/source add . && "
        "git -C /root/source -c user.name=Test -c user.email=test@example.invalid "
        "commit -m Fixture"
    )
    controller.succeed("tmux new-session -d -s deploy")
    controller.succeed("tmux set-window-option -t deploy remain-on-exit on")
    command = "cd /root/source && deploy --local --no-merge target"
    controller.succeed(f"tmux respawn-pane -k -t deploy {shlex.quote(command)}")
    try:
        controller.wait_until_succeeds(
            "test \"$(tmux display-message -p -t deploy '#{pane_dead}')\" = 1",
            timeout=300,
        )
    finally:
        print(controller.succeed("tmux capture-pane -p -S - -t deploy"))
    status = controller.succeed("tmux display-message -p -t deploy '#{pane_dead_status}'").strip()
    if status != "0":
        print(builder.succeed("journalctl -b --no-pager -n 120"))
    assert status == "0"


start_all()
builder.wait_for_unit("sshd.service")
target.wait_for_unit("sshd.service")
controller.wait_for_unit("multi-user.target")

with subtest("a fresh builder-only host cannot build without its private key"):
    target.succeed("test ! -e /run/secrets/nix/builder_private_key")
    failure = target.fail(
        """nix build --impure --no-link --expr 'builtins.derivation {
          name = "missing-builder-key";
          system = builtins.currentSystem;
          builder = "/bin/sh";
          args = [ "-c" "echo probe > $out" ];
        }' 2>&1""",
        timeout=60,
    )
    assert "builder_private_key" in failure
    assert "Permission denied" in failure

with subtest("install-time host identity enables real SOPS decryption on first boot"):
    install_with_identity()
    installed = boot_installed_system()
    installed.wait_for_unit("sops-install-secrets.service")
    installed.wait_for_unit("sshd.service")
    installed.succeed("test -s /run/secrets/nix/builder_private_key")
    assert installed.succeed("stat -c %a /run/secrets/nix/builder_private_key").strip() == "400"
    assert installed.succeed("getent shadow bootstrap | cut -d: -f2").strip() == "!"
    controller.succeed("ssh target true")
    assert installed.succeed("cat /etc/bootstrap-marker").strip() == "before"

with subtest("the first deployment builds its uncached helper remotely and activates"):
    assert installed.succeed("nix config show max-jobs").strip() == "0"
    builder.succeed("test -z \"$(find /nix/store -maxdepth 1 -name '*-bootstrap-deploy-helper')\"")
    deploy_uncached_helper()
    assert installed.succeed("cat /etc/bootstrap-marker").strip() == "after"
    builder.succeed("test -n \"$(find /nix/store -maxdepth 1 -name '*-bootstrap-deploy-helper')\"")
    controller.succeed("ssh target true")
