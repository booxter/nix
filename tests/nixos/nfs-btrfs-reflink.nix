{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "nfs-btrfs-reflink";
  imports = [ (import ./nfs-btrfs-reflink/arr.nix { inherit pkgs; }) ];

  nodes.server = {
    boot.supportedFilesystems = [ "btrfs" ];
    virtualisation.emptyDiskImages = [ 512 ];
    environment.systemPackages = [
      pkgs.btrfs-progs
      pkgs.python314
    ];
    environment.etc."reflink-probe.py".source = ./nfs-btrfs-reflink/probe.py;
    networking.firewall.enable = false;
    services.nfs.server = {
      enable = true;
      exports = ''
        /srv/media *(rw,sync,no_subtree_check,no_root_squash,fsid=10)
        /srv/media/torrents *(rw,sync,no_subtree_check,no_root_squash,fsid=11)
      '';
    };
  };

  nodes.server.services.opentracker.enable = true;
  nodes.server.systemd.tmpfiles.rules = [ "d /srv/seeds 0755 transmission transmission - -" ];
  # Follow nixpkgs' bittorrent test: a real tracker and Transmission seeder.
  nodes.server.services.transmission = {
    enable = true;
    package = pkgs.transmission_4;
    settings = {
      download-dir = "/srv/seeds";
      dht-enabled = false;
      lpd-enabled = false;
      pex-enabled = false;
    };
  };
  nodes.server.systemd.services.test-indexer.serviceConfig = {
    ExecStart = "${pkgs.python314}/bin/python ${./nfs-btrfs-reflink/indexer.py}";
    WorkingDirectory = "/srv/indexer";
  };

  nodes.client = { lib, ... }: {
    # NFS discovers the child while resolving this path. A systemd automount
    # would cover that discovered mount and make path lookup fail with ELOOP.
    systemd.mounts = [
      {
        what = "server:/srv/media/torrents";
        where = "/mnt/media/torrents";
        type = "nfs";
        options = "vers=4.2";
      }
    ];
    boot.supportedFilesystems = [ "nfs" ];
    environment.systemPackages = [ pkgs.python314 ];
    environment.etc."reflink-probe.py".source = ./nfs-btrfs-reflink/probe.py;
    environment.etc."shelfmark-import.py".source = ./nfs-btrfs-reflink/shelfmark-import.py;
    networking.firewall.enable = false;
    users.groups.media.gid = 1000;
    users.users.importer = {
      isSystemUser = true;
      uid = 1000;
      group = "media";
    };
    services.transmission = {
      enable = true;
      package = pkgs.transmission_4;
      user = "importer";
      group = "media";
      settings = {
        download-dir = "/mnt/media/torrents/shelfmark";
        dht-enabled = false;
        lpd-enabled = false;
        pex-enabled = false;
        umask = 2;
      };
    };
    systemd.services.transmission.wantedBy = lib.mkForce [ ];
    services.shelfmark = {
      enable = true;
      package = pkgs.shelfmark;
      environment = {
        AUTH_METHOD = "none";
        INGEST_DIR = "/mnt/media/library/books";
        DESTINATION_AUDIOBOOK = "/mnt/media/library/audiobooks";
        HARDLINK_TORRENTS = "false";
        HARDLINK_TORRENTS_AUDIOBOOK = "false";
        FILE_ORGANIZATION = "rename";
        FILE_ORGANIZATION_AUDIOBOOK = "rename";
        PROWLARR_ENABLED = "true";
        PROWLARR_URL = "http://server:9000";
        PROWLARR_API_KEY = "test-indexer-key";
        PROWLARR_TORRENT_CLIENT = "transmission";
        PROWLARR_TORRENT_ACTION = "keep";
        TRANSMISSION_URL = "http://127.0.0.1:9091";
        TRANSMISSION_DOWNLOAD_DIR = "/mnt/media/torrents/shelfmark";
      };
    };
    systemd.services.shelfmark = {
      wantedBy = lib.mkForce [ ];
      serviceConfig = {
        User = "importer";
        Group = "media";
        UMask = lib.mkForce "0002";
        ReadWritePaths = [
          "/mnt/media/torrents/shelfmark"
          "/mnt/media/library/books"
          "/mnt/media/library/audiobooks"
        ];
      };
    };
  };

  testScript = builtins.readFile ./nfs-btrfs-reflink/test.py;
}
