{
  config,
  lib,
  ...
}:
let
  mediaPath = config.host.srvarrPaths.mediaDir;
  networkOnlineUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
  };
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
  host.nfs.mounts.media = mediaPath;

  systemd.tmpfiles.rules = [
    # Keep the legacy media-root tmpfiles rule in eval for parity with the old
    # stack; the generated tmpfiles file below still filters NFS-managed paths.
    "d '${mediaPath}'  2775 root media - -"
  ];

  environment.etc."tmpfiles.d/00-nixos.conf".text = ''
    # This file is created automatically and should not be modified.
    # Please change the option `systemd.tmpfiles.rules` instead.
    # Filtered on srvarr: /data/media is an NFS export managed on beast.

    ${lib.concatStringsSep "\n" filteredTmpfilesRules}
  '';

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
  systemd.services.lidarr.unitConfig = requiresMediaMount;
  systemd.services.transmission.unitConfig = requiresMediaMount;
  systemd.services.sabnzbd.unitConfig = requiresMediaMount;
}
