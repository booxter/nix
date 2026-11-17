# ruff: noqa: F821
# The NixOS test driver supplies server, client, and subtest.

import shlex


def probe(machine, action, *arguments, root="/mnt/media"):
    command = ["python3", "/etc/reflink-probe.py", "--root", root, action, *arguments]
    return machine.succeed(shlex.join(command))


def check_shared_copy(name):
    probe(client, "copy", name)
    usage = server.succeed(f"btrfs filesystem du --raw /srv/media/{name}.bin")
    print(usage)
    total, exclusive, shared = map(int, usage.splitlines()[-1].split()[:3])
    assert total > 0 and exclusive == 0 and shared == total, usage

    probe(client, "independent-write", name)


start_all()
server.wait_for_unit("multi-user.target")
client.wait_for_unit("multi-user.target")

with subtest("export separate subvolumes with deliberately colliding inode numbers"):
    server.succeed("systemctl stop nfs-server")
    server.succeed("mkfs.btrfs -f /dev/vdb")
    server.succeed("mkdir -p /srv/media")
    server.succeed("mount /dev/vdb /srv/media")
    probe(server, "seed-library", root="/srv/media")
    server.succeed("btrfs subvolume create /srv/media/torrents")
    probe(server, "seed-torrent", root="/srv/media")
    # Btrfs subvolumes have independent inode namespaces. Separate export fsids
    # alone do not make NFS switch identities when traversing into a subvolume;
    # nfsd needs a server-side mount boundary too. Without this mount, distinct
    # files can have identical client (device, inode) pairs, making shutil reject
    # a copy with SameFileError. Mounting the child only on the client is not enough.
    server.succeed("mount -t btrfs -o subvol=torrents /dev/vdb /srv/media/torrents")
    server.succeed("systemctl start nfs-server")
    print(server.succeed("exportfs -v"))
    server.wait_for_open_port(2049)
    client.succeed("mkdir -p /mnt/media")
    client.succeed("mount -t nfs -o vers=4.2 server:/srv/media /mnt/media")

with subtest("parent mount discovers the separately mounted and exported subvolume"):
    print(probe(client, "identity"))
    check_shared_copy("implicit-child-copy")

with subtest("explicit child mount preserves identity and shared copies"):
    client.succeed("mount -t nfs -o vers=4.2 server:/srv/media/torrents /mnt/media/torrents")
    print(probe(client, "identity"))
    check_shared_copy("explicit-child-copy")
