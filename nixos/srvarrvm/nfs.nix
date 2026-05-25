{
  config,
  hostInventory,
  lib,
  ...
}:
let
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
  networkOnlineUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
  };
  requiresMediaMount = networkOnlineUnitDeps // {
    RequiresMountsFor = mediaPath;
  };
  wgUnitDepsBase = networkOnlineUnitDeps // {
    After = networkOnlineUnitDeps.After ++ [ "wg.service" ];
    BindsTo = [ "wg.service" ];
    PartOf = [ "wg.service" ];
  };
  wgUnitDepsWithMount = wgUnitDepsBase // requiresMediaMount;
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
  boot.supportedFilesystems = [ "nfs" ];
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

  users.groups.media.gid = hostInventory.site.gids.media;
  users.users.${config.host.srvarr.services.bazarr.user}.extraGroups = [ "media" ];

  # Make services that r/w to NFS require the media mount.
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
  systemd.services.shelfmark.unitConfig = requiresMediaMount;
  systemd.services.transmission.unitConfig = wgUnitDepsWithMount;
  systemd.services.sabnzbd.unitConfig = wgUnitDepsWithMount;
}
