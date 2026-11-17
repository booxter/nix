# ruff: noqa: F821
# The NixOS test driver supplies server, client, and subtest.

import json
import shlex


def probe(machine, action, *arguments, root="/mnt/media"):
    command = ["python3", "/etc/reflink-probe.py", "--root", root, action, *arguments]
    return machine.succeed(shlex.join(command))


def check_shared_file(path):
    usage = server.succeed(shlex.join(["btrfs", "filesystem", "du", "--raw", path]))
    print(usage)
    total, exclusive, shared = map(int, usage.splitlines()[-1].split()[:3])
    assert total > 0 and exclusive == 0 and shared == total, usage


def check_imports(manifest):
    destinations = json.loads(client.succeed(shlex.join(["cat", manifest])))
    for destination in destinations:
        check_shared_file(destination.replace("/mnt/media/", "/srv/media/", 1))


def check_shared_copy(name):
    probe(client, "copy", name)
    check_shared_file(f"/srv/media/{name}.bin")
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

with subtest("Shelfmark imports ebooks and audiobooks through its service sandbox"):
    server.succeed(
        "mkdir -p /srv/media/torrents/shelfmark "
        "/srv/media/library/books /srv/media/library/audiobooks"
    )
    server.succeed("chown -R 1000:1000 /srv/media/torrents/shelfmark /srv/media/library")
    probe(server, "seed-releases", root="/srv/seeds")
    server.succeed("mkdir -p /srv/indexer")
    server.wait_for_unit("transmission")
    server.wait_for_open_port(6969)
    for suffix in ("epub", "m4b"):
        server.succeed(
            f"transmission-create /srv/seeds/source.{suffix} --private "
            f"--tracker http://server:6969/announce --outfile /srv/indexer/source.{suffix}.torrent"
        )
        server.succeed(
            f"transmission-remote --add /srv/indexer/source.{suffix}.torrent "
            "--download-dir /srv/seeds --no-portmap --no-dht"
        )
    server.succeed("systemctl start test-indexer")
    client.succeed("systemctl start transmission shelfmark")
    client.wait_for_open_port(8084)
    client.wait_until_succeeds("curl --fail http://127.0.0.1:8084/api/health")
    try:
        client.succeed("python3 /etc/shelfmark-import.py", timeout=400)
    finally:
        print(client.succeed("journalctl -u shelfmark -u transmission --no-pager"))
        print(server.succeed("journalctl -u test-indexer --no-pager"))
    check_imports("/tmp/shelfmark-results.json")

with subtest("Radarr falls back from hardlinks when importing across subvolumes"):
    server.succeed("mkdir -p /srv/media/torrents/radarr /srv/media/library/movies")
    server.succeed("chown 1000:1000 /srv/media/torrents/radarr /srv/media/library/movies")
    server.succeed(
        "ffmpeg -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=24 "
        "-t 2 -c:v ffv1 '/srv/media/torrents/radarr/Reflink Movie (2020).mkv'"
    )
    client.succeed("systemctl start radarr")
    client.wait_for_open_port(7878)
    try:
        client.succeed("python3 /etc/arr-import.py", timeout=180)
    finally:
        print(client.succeed("journalctl -u radarr --no-pager"))
    check_imports("/tmp/arr-results.json")

with subtest("parent snapshots retain the library and exclude torrent payloads"):
    server.succeed("btrfs subvolume snapshot -r /srv/media /srv/media/snapshot")
    server.succeed("test -f /srv/media/snapshot/library.bin")
    server.fail("test -e /srv/media/snapshot/torrents/source.bin")
