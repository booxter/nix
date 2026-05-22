{
  config,
  lib,
  outputs,
  pkgs,
  hostInventory,
  ...
}:
let
  mediaLibraries = import ./media-libraries.nix;
  mediaPaths = import ./media-paths.nix;
  mediaRoot = "/volume2/Media";
  mediaTorrentRoot = "${mediaRoot}/torrents";
  mediaUsenetRoot = "${mediaRoot}/usenet";
  nfsSubnet = hostInventory.site.lan.cidr;
  jellyfinLoggingConfig = pkgs.writeText "jellyfin-logging.json" (
    builtins.toJSON {
      Serilog = {
        MinimumLevel = {
          Default = "Information";
          Override = {
            Microsoft = "Warning";
            System = "Warning";
            "Jellyfin.Api.Controllers.DynamicHlsController" = "Debug";
            "Jellyfin.Api.Helpers.HlsHelpers" = "Debug";
            "Emby.Server.Implementations.HttpServer" = "Debug";
            "Emby.Server.Implementations.Session" = "Debug";
          };
        };
      };
    }
  );
  # Pin export IDs so clients see stable export identities across server restarts.
  mkNfsExport =
    { path, fsid }: "${path} ${nfsSubnet}(rw,async,no_subtree_check,fsid=${toString fsid})";
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
  nfsPorts = [
    hostInventory.site.ports.nfs # nfsd
  ];
  joinMediaParts = pkgs.callPackage ../../pkgs/join-media-parts { };
in
{
  imports = [
    (import ../../disko { })
    ./backup-server.nix
    ./btrfs.nix
    ./disk-bays.nix
    ./jellyfin-exporter.nix
    ./jellyfin-backup.nix
    ./jellarr.nix
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

  # NFS exports matching existing clients.
  services.nfs.server = {
    enable = true;
    exports = ''
      ${mkNfsExport {
        path = "/volume2/Media";
        fsid = 10; # media export
      }}
      ${mkNfsExport {
        path = "/volume2/nix-cache";
        fsid = 11; # binary cache export
      }}
    '';
  };
  systemd.services.nfs-server.unitConfig.RequiresMountsFor = [
    "/volume2"
    "/volume2/Media"
    "/volume2/nix-cache"
  ];

  services.nfs.settings = {
    nfsd = {
      vers3 = "n";
      vers4 = "y";
    };
  };

  services.rpcbind.enable = lib.mkForce false;

  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };
  system.activationScripts.jellyfinLoggingConfig.text = ''
    ${pkgs.coreutils}/bin/install -d -m 0700 -o jellyfin -g jellyfin /var/lib/jellyfin/config
    ${pkgs.coreutils}/bin/install -m 0600 -o jellyfin -g jellyfin ${jellyfinLoggingConfig} /var/lib/jellyfin/config/logging.json
  '';
  users.groups.media.gid = 169;
  users.users.jellyfin.extraGroups = [
    "media"
    "render"
    "video"
  ];
  systemd.services.jellyfin.unitConfig.RequiresMountsFor = "/media";
  systemd.services.jellyfin.restartTriggers = [ jellyfinLoggingConfig ];

  host.observability.client.blackbox.enable = true;

  sops = {
    defaultSopsFile = ../../secrets/beast.yaml;
  };

  # Keep the existing /media path expected by Jellyfin/Jellarr.
  fileSystems."/media" = {
    device = "/volume2/Media";
    fsType = "none";
    options = [
      "bind"
      "nofail"
      "x-systemd.requires-mounts-for=/volume2"
    ];
  };

  networking.firewall.allowedTCPPorts = nfsPorts;
  networking.firewall.allowedUDPPorts = nfsPorts;

  networking.resolvconf.enable = true;

  systemd.tmpfiles.rules = [
  ]
  ++ lib.concatMap (spec: mkTmpfilesDir spec.path spec.mode spec.user spec.group) mediaDirSpecs;

  environment.systemPackages =
    with pkgs;
    [
      intel-gpu-tools
      libva-utils
    ]
    ++ [ joinMediaParts ];

  # Acceleration setup: https://nixos.wiki/wiki/Jellyfin
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-compute-runtime
      vpl-gpu-rt
    ];
  };
}
