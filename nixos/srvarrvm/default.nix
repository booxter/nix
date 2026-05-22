{
  lib,
  config,
  inputs,
  hostInventory,
  ...
}:
let
  srvarrSpec = hostInventory.nixosHostSpecsByName.srvarr;
  beastNfsAddress = hostInventory.dhcpReservationsByHostname.beast.ip;
  mediaPath = "/data/media";
  # Resilient NFS client behavior:
  # - hard: block I/O until the server is back (avoid soft I/O errors).
  # - nofail/_netdev/network-online: don't fail boot when NAS is down.
  # - automount + idle timeout: remount on demand after outages.
  # - mount-timeout: fail each mount attempt quickly, retry on next access.
  mediaMountOptions = [
    "nfsvers=4"
    "hard"
    "nofail"
    "_netdev"
    "noatime"
    "x-systemd.automount"
    "x-systemd.idle-timeout=0"
    "x-systemd.mount-timeout=30s"
    "x-systemd.requires=network-online.target"
    "x-systemd.after=network-online.target"
  ];
  media = {
    device = "${beastNfsAddress}:/volume2/Media";
    fsType = "nfs";
    options = mediaMountOptions;
  };
  wgBridgeAddress = srvarrSpec.wgNamespace.bridgeAddress;
  wgNamespaceAddress = srvarrSpec.wgNamespace.namespaceAddress;
  wgConservativeUploadRateMbit = 8;
  # Keep Transmission a little below the conservative tc floor so
  # Transmission's own scheduler remains the bottleneck and can favor
  # private-tracker torrents before traffic hits the kernel shaper.
  transmissionConservativeUploadLimitKBps = builtins.floor (
    (wgConservativeUploadRateMbit * 1000.0 / 8.0) * 0.95
  );
  transmissionNonPreferredLowPriorityRatio = 3.0;
  networkOnlineUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
  };
  wgUnitDepsBase = networkOnlineUnitDeps // {
    After = networkOnlineUnitDeps.After ++ [ "wg.service" ];
    BindsTo = [ "wg.service" ];
    PartOf = [ "wg.service" ];
  };
  wgTimerDeps = {
    After = [ "wg.service" ];
  };
  wgUnitDepsWithMount = wgUnitDepsBase // requiresMediaMount;
  requiresMediaMount = networkOnlineUnitDeps // {
    RequiresMountsFor = mediaPath;
  };
  servarrUMask = lib.mkForce "0002";
  isNfsMediaTmpfilesRule =
    rule:
    let
      fields = builtins.filter (field: field != "") (lib.splitString " " rule);
      pathToken = if builtins.length fields > 1 then builtins.elemAt fields 1 else "";
    in
    builtins.any (prefix: lib.hasPrefix prefix pathToken) [
      mediaPath
      "'${mediaPath}"
    ];
  filteredTmpfilesRules = builtins.filter (
    rule: !isNfsMediaTmpfilesRule rule
  ) config.systemd.tmpfiles.rules;
in
{
  _module.args = {
    inherit
      networkOnlineUnitDeps
      transmissionConservativeUploadLimitKBps
      transmissionNonPreferredLowPriorityRatio
      wgBridgeAddress
      wgConservativeUploadRateMbit
      wgNamespaceAddress
      wgTimerDeps
      wgUnitDepsBase
      wgUnitDepsWithMount
      ;
  };

  imports = [
    inputs.nixarr.nixosModules.default
    ./aurral.nix
    ./backup.nix
    ./glance.nix
    ./nightly-speedtest.nix
    ./sabnzbd.nix
    ./sabnzbd-exporter.nix
    ./transmission.nix
    ./transmission-torrent-cleaner.nix
    ./transmission-tracker-prioritizer.nix
    ./vpn.nix
  ];

  sops.defaultSopsFile = ../../secrets/prox-srvarrvm.yaml;

  # NFS mounts with media
  boot.supportedFilesystems = [ "nfs" ];
  boot.kernelModules = [ "ifb" ];
  services.rpcbind.enable = true;

  # local qemu vms override filesystems
  # TODO: move this special handling for FS to mkVM?
  fileSystems."${mediaPath}" = media;
  virtualisation.vmVariant.virtualisation.fileSystems."${mediaPath}" = media;
  environment.etc."tmpfiles.d/00-nixos.conf".text = ''
    # This file is created automatically and should not be modified.
    # Please change the option `systemd.tmpfiles.rules` instead.
    # Filtered on srvarr: /data/media is an NFS export managed on beast.

    ${lib.concatStringsSep "\n" filteredTmpfilesRules}
  '';

  users.groups.media.gid = 169;
  users.users.${config.util-nixarr.globals.bazarr.user}.extraGroups = [ "media" ];

  # Service-specific systemd tweaks.
  systemd.services.radarr = {
    serviceConfig.UMask = servarrUMask;
    unitConfig = requiresMediaMount;
  };
  systemd.services.sonarr = {
    serviceConfig.UMask = servarrUMask;
    unitConfig = requiresMediaMount;
  };
  systemd.services.bazarr = {
    serviceConfig.UMask = servarrUMask;
    unitConfig = requiresMediaMount;
  };
  # Make services that r/w to NFS require the media mount.
  systemd.services.audiobookshelf = {
    # nixarr points Audiobookshelf at an absolute data dir under /data, but the
    # upstream module passes that through to StateDirectory=. systemd ignores
    # absolute StateDirectory paths and logs a warning on every unit reload, so
    # clear just that directive and keep the rest of the service as generated.
    serviceConfig.StateDirectory = lib.mkForce null;
    unitConfig = requiresMediaMount;
  };
  systemd.services.seerr.unitConfig = requiresMediaMount;
  systemd.services.lidarr.unitConfig = requiresMediaMount;
  systemd.services.prowlarr.unitConfig = networkOnlineUnitDeps;
  systemd.services.shelfmark.unitConfig = requiresMediaMount;

  nixarr = {
    enable = true;
    seerr = {
      enable = true;
      openFirewall = true;
    };
    prowlarr = {
      enable = true;
      openFirewall = true;
    };
    radarr = {
      enable = true;
      openFirewall = true;
    };
    lidarr = {
      enable = true;
      openFirewall = true;
    };
    shelfmark = {
      enable = true;
      host = "0.0.0.0";
      openFirewall = true;
    };
    sonarr = {
      enable = true;
      openFirewall = true;
    };
    bazarr = {
      enable = true;
      openFirewall = true;
    };
    audiobookshelf = {
      enable = true;
      host = "0.0.0.0";
      openFirewall = true;
    };

  };

}
