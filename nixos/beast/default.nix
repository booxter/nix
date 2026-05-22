{
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  mediaLibraries = import ./media-libraries.nix;
  mediaPaths = import ./media-paths.nix;
  mediaRoot = "/volume2/Media";
  mediaTorrentRoot = "${mediaRoot}/torrents";
  mediaUsenetRoot = "${mediaRoot}/usenet";
  mkTmpfilesDir = path: mode: user: group: [
    "d ${path} ${mode} ${user} ${group} - -"
    "z ${path} ${mode} ${user} ${group} - -"
  ];
  mediaDirSpecs = [
    {
      path = mediaPaths.sourceLibraryRoot;
      mode = "2775";
      user = "root";
      group = "media";
    }
    {
      path = "${mediaPaths.sourceLibraryRoot}/books";
      mode = "2775";
      user = "root";
      group = "media";
    }
    {
      path = "${mediaPaths.sourceLibraryRoot}/audiobooks";
      mode = "2775";
      user = "root";
      group = "media";
    }
    {
      path = "${mediaPaths.sourceLibraryRoot}/podcasts";
      mode = "2775";
      user = "root";
      group = "media";
    }
    {
      path = "${mediaPaths.sourceLibraryRoot}/flows";
      mode = "2775";
      user = "root";
      group = "media";
    }
    {
      path = mediaTorrentRoot;
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/.incomplete";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/.watch";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/manual";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/lidarr";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/radarr";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/sonarr";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = "${mediaTorrentRoot}/shelfmark";
      mode = "0755";
      user = "70";
      group = "media";
    }
    {
      path = mediaUsenetRoot;
      mode = "0755";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/.incomplete";
      mode = "0755";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/.watch";
      mode = "0755";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/watch";
      mode = "0755";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/manual";
      mode = "0775";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/lidarr";
      mode = "0775";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/radarr";
      mode = "0775";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/sonarr";
      mode = "0775";
      user = "38";
      group = "media";
    }
    {
      path = "${mediaUsenetRoot}/shelfmark";
      mode = "0775";
      user = "38";
      group = "media";
    }
  ]
  ++ map (library: {
    path = "${mediaPaths.sourceLibraryRoot}/${library.path}";
    mode = "2775";
    user = "root";
    group = "media";
  }) mediaLibraries;
in
{
  imports = [
    (import ../../disko { })
    ./backup-server.nix
    ./btrfs.nix
    ./disk-bays.nix
    ./igpu.nix
    ./jellyfin.nix
    ./jellyfin-exporter.nix
    ./jellyfin-backup.nix
    ./jellarr.nix
    ./nfs.nix
    ./nginx.nix
    ./pause.nix
    ./raid.nix
    ./ups.nix
  ];

  # Pin this host to the latest stable release channel (critical infra).
  users.users.ihrachyshka.hashedPassword = "$6$gQ7Gm5b2aq7qPn7W$dcuDT19.SJ88xPA4tQHbscdJDMo3wK.UXGhffrohh7YU4QAzcmRk3GKPNku.BnGrkgDYvZXm/4tBfT.NP6eF.1";

  # Use the freshest kernel available on the stable channel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Host critical services; keep upgrades on Monday, separate from the fleet's
  # default Saturday schedule, but still leave room for local backups and later
  # cloud offload jobs after the reboot window work settles.
  system.autoUpgrade.dates = "Mon 04:00";
  system.autoUpgrade.randomizedDelaySec = "15min";

  # IPMI quirks (beast):
  # - If BMC gets into a broken state, run: sudo ipmitool raw 0x32 0x66
  # - On first setup, use a simple password (no special chars) or later logins can fail.

  users.groups.media.gid = hostInventory.site.gids.media;

  host.observability.client.blackbox.enable = true;

  sops = {
    defaultSopsFile = ../../secrets/beast.yaml;
  };

  networking.resolvconf.enable = true;

  systemd.tmpfiles.rules = lib.concatMap (
    spec: mkTmpfilesDir spec.path spec.mode spec.user spec.group
  ) mediaDirSpecs;

  environment.systemPackages = [ pkgs.join-media-parts ];
}
