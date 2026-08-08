{ config, ... }:
let
  mediaPath = config.host.srvarrPaths.mediaDir;
  networkOnlineUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
  };
  requiresMediaMount = networkOnlineUnitDeps // {
    RequiresMountsFor = mediaPath;
  };
in
{
  host.nfs.mounts.media = mediaPath;

  # Make services that r/w to NFS require the media mount.
  systemd.services.transmission.unitConfig = requiresMediaMount;
  systemd.services.sabnzbd.unitConfig = requiresMediaMount;
}
