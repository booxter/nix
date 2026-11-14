# ruff: noqa: F821
# The NixOS test driver supplies machine and subtest.

import json


def md_value(field):
    return machine.succeed(f"cat /sys/block/md127/md/{field}").strip()


def check_maintenance_skipped():
    machine.succeed("systemctl start nixos-upgrade nixos-reboot-if-needed")
    machine.fail("test -e /run/upgrade-ran")
    machine.fail("test -e /run/reboot-ran")


def check_payload():
    machine.succeed("sha256sum --check /root/payload.sha256")


machine.start()
machine.wait_for_unit("multi-user.target")
machine.wait_for_open_port(22)

with subtest("create RAID6 and data before expansion"):
    machine.succeed(
        "mdadm --create /dev/md127 --metadata=1.2 --level=6 --raid-devices=4 "
        "--uuid=11112222:33334444:55556666:77778888 --name=reshape-test "
        "--homehost=machine --data-offset=2048 --bitmap=none --run "
        "/dev/vdb /dev/vdc /dev/vdd /dev/vde"
    )
    machine.wait_until_succeeds("test $(cat /sys/block/md127/md/sync_action) = idle")
    machine.succeed("mkfs.btrfs -L reshape-test /dev/md127")
    machine.succeed("udevadm settle; systemctl reset-failed; systemctl start bulk.mount")
    machine.succeed("dd if=/dev/urandom of=/bulk/payload bs=1M count=384 status=none")
    machine.succeed("sha256sum /bulk/payload > /root/payload.sha256; sync")
    check_payload()

with subtest("active and paused reshapes skip unattended maintenance"):
    machine.succeed("echo 1000 > /sys/block/md127/md/sync_speed_min")
    machine.succeed("echo 1000 > /sys/block/md127/md/sync_speed_max")
    machine.succeed("mdadm --manage /dev/md127 --add /dev/vdf")
    machine.succeed("mdadm --grow /dev/md127 --raid-devices=5 --backup-file=/root/reshape.backup")
    machine.wait_until_succeeds("test $(cat /sys/block/md127/md/sync_action) = reshape")
    check_maintenance_skipped()
    # Get beyond the initial critical section, then pause at a real checkpoint.
    machine.wait_until_succeeds(
        "test $(cat /sys/block/md127/md/reshape_position) -gt 65536", timeout=120
    )
    machine.succeed("echo frozen > /sys/block/md127/md/sync_action")
    machine.wait_until_succeeds("test $(cat /sys/block/md127/md/sync_action) = frozen")
    assert md_value("reshape_position") != "none"
    check_maintenance_skipped()
    machine.succeed("umount /bulk")
    machine.succeed("systemctl reboot", timeout=10)
    machine.wait_for_shutdown()
    machine.start()

with subtest("unfinished reshape does not prevent SSH after reboot"):
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_open_port(22)
    machine.wait_until_succeeds("test -e /sys/block/md127/md/array_state")
    assert md_value("array_state") == "inactive"
    machine.fail("findmnt /bulk")
    machine.fail("systemctl is-active bulk-consumer.service")
    machine.fail("test -e /bulk/consumer-started")
    check_maintenance_skipped()

with subtest("operator recovery resumes reshape and preserves data"):
    machine.succeed("mdadm --stop /dev/md127")
    machine.succeed(
        "mdadm --assemble /dev/md127 --uuid=11112222:33334444:55556666:77778888 "
        "/dev/vdb /dev/vdc /dev/vdd /dev/vde /dev/vdf"
    )
    machine.succeed("echo 200000 > /sys/block/md127/md/sync_speed_max")
    machine.succeed("echo 100000 > /sys/block/md127/md/sync_speed_min")
    machine.wait_until_succeeds(
        "test $(cat /sys/block/md127/md/reshape_position) = none", timeout=180
    )
    machine.succeed("systemctl reset-failed; systemctl start bulk.mount bulk-consumer")
    check_payload()
    machine.succeed("test -e /bulk/consumer-started")
    assert md_value("degraded") == "0"
    assert md_value("raid_disks") == "5"
    machine.succeed("systemctl start nixos-upgrade nixos-reboot-if-needed")
    machine.succeed("test -e /run/upgrade-ran; test -e /run/reboot-ran")

with subtest("vacations independently hold maintenance after reshape completes"):
    current_time = machine.succeed("date +%s").strip()
    machine.succeed("date --set '2020-01-02 12:00:00'")
    machine.succeed("rm /run/upgrade-ran /run/reboot-ran")
    check_maintenance_skipped()
    machine.succeed(f"date --set @{current_time}")
    machine.succeed("systemctl start nixos-upgrade nixos-reboot-if-needed")
    machine.succeed("test -e /run/upgrade-ran; test -e /run/reboot-ran")

with subtest("completed array assembles automatically on subsequent boots"):
    machine.succeed("systemctl reboot", timeout=10)
    machine.wait_for_shutdown()
    machine.start()
    machine.wait_for_unit("bulk-consumer.service")
    machine.wait_for_open_port(22)
    check_payload()
    mounts = json.loads(machine.succeed("findmnt --json /bulk"))
    assert mounts["filesystems"][0]["fstype"] == "btrfs"
