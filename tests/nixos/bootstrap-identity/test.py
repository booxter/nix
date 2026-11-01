# ruff: noqa: F821
# The NixOS test driver supplies the machines and QEMU executable.

import base64
import json
import shlex
import socket
import subprocess
import time
from pathlib import Path


class GuestAgent:
    """Use the real virtio guest-agent channel, as Proxmox does."""

    def __init__(self, address):
        self.connection = socket.socket(socket.AF_UNIX)
        self.connection.settimeout(30)
        self.connection.connect(str(address))
        self.stream = self.connection.makefile("rwb")
        self.synchronize()

    def synchronize(self):
        identifier = time.monotonic_ns()
        self.connection.sendall(b"\xff")
        self.send("guest-sync-delimited", {"id": identifier})
        # The reset byte can generate a parse-error response. QGA requires
        # discarding everything up to the synchronization response's sentinel.
        while True:
            byte = self.stream.read(1)
            if not byte:
                raise EOFError("Guest agent disconnected during synchronization")
            if byte == b"\xff":
                break
        assert json.loads(self.stream.readline())["return"] == identifier

    def send(self, command, arguments):
        request = {"execute": command, "arguments": arguments}
        self.stream.write(json.dumps(request).encode() + b"\n")
        self.stream.flush()

    def request(self, command, arguments):
        self.send(command, arguments)
        response = json.loads(self.stream.readline())
        assert "error" not in response, response
        return response["return"]

    def execute(self, command, data=None, *, expected_status=0):
        arguments = {"path": command[0], "arg": command[1:], "capture-output": True}
        if data is not None:
            arguments["input-data"] = base64.b64encode(data).decode()
        process = self.request("guest-exec", arguments)
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            status = self.request("guest-exec-status", {"pid": process["pid"]})
            if status["exited"]:
                assert status.get("exitcode") == expected_status, status
                return
            time.sleep(0.1)
        raise TimeoutError(f"Guest command did not finish: {command[0]}")

    def deliver_identity(self, path, *, expected_status=0):
        self.execute(
            ["/run/current-system/sw/bin/proxmox-install-identity"],
            Path(path).read_bytes(),
            expected_status=expected_status,
        )

    def close(self):
        self.stream.close()
        self.connection.close()


def boot_target(name, disk, *, iso=None, agent_socket=None):
    command = [
        QEMU,
        "-cpu",
        "max",
        "-m",
        "2048",
        "-drive",
        f"file={disk},id=drive1,if=none,werror=report",
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
    if iso is not None:
        command.extend(["-cdrom", iso, "-boot", "order=d"])
    if agent_socket is not None:
        command.extend(
            [
                "-device",
                "virtio-serial-pci,id=agent",
                "-chardev",
                f"socket,id=qga,path={agent_socket},server=on,wait=off",
                "-device",
                "virtserialport,bus=agent.0,chardev=qga,name=org.qemu.guest_agent.0",
            ]
        )
    machine = create_machine(start_command=shlex.join(command), name=name)
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
controller.wait_for_unit("multi-user.target")

disk = Path.cwd() / "installed.qcow2"
agent_socket = Path.cwd() / "guest-agent.sock"
subprocess.run([QEMU_IMG, "create", "-f", "qcow2", str(disk), "40G"], check=True)
iso_images = list(Path(INSTALLER_ISO_DIRECTORY).glob("*.iso"))
assert len(iso_images) == 1, iso_images
target = boot_target("target", disk, iso=str(iso_images[0]), agent_socket=agent_socket)
target.wait_for_unit("qemu-guest-agent.service")
target.wait_until_succeeds("ping -c1 -W1 builder")
guest = GuestAgent(agent_socket)

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

with subtest("missing and mismatched identities cannot format the disk"):
    target.fail("blkid -p /dev/vda")
    marker = "bootstrap-disk-marker"
    target.succeed(f"printf %s {marker} | dd of=/dev/vda conv=notrunc status=none")
    guest.deliver_identity(WRONG_KEY, expected_status=1)
    assert target.succeed(f"head -c {len(marker)} /dev/vda") == marker

with subtest("install-time host identity enables real SOPS decryption on first boot"):
    guest.deliver_identity(HOST_KEY)
    guest.close()
    # The pinned auto-installer reboots after installing. The test driver's
    # -no-reboot stops QEMU, letting us boot the installed disk without the ISO.
    target.wait_for_shutdown()
    installed = boot_target("installed", disk)
    installed.wait_for_unit("sops-install-secrets.service")
    installed.wait_for_unit("sshd.service")
    installed.succeed("test -s /run/secrets/nix/builder_private_key")
    assert installed.succeed("stat -c %a /run/secrets/nix/builder_private_key").strip() == "400"
    assert (
        installed.succeed("getent shadow bootstrap | cut -d: -f2").strip() == "!bootstrap-fixture"
    )
    controller.succeed("ssh target true")
    assert installed.succeed("cat /etc/bootstrap-marker").strip() == "before"

with subtest("the first deployment builds its uncached helper remotely and activates"):
    assert installed.succeed("nix config show max-jobs").strip() == "0"
    builder.succeed("test -z \"$(find /nix/store -maxdepth 1 -name '*-bootstrap-deploy-helper')\"")
    deploy_uncached_helper()
    assert installed.succeed("cat /etc/bootstrap-marker").strip() == "after"
    builder.succeed("test -n \"$(find /nix/store -maxdepth 1 -name '*-bootstrap-deploy-helper')\"")
    controller.succeed("ssh target true")
