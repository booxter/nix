{
  config,
  lib,
  utils,
  ...
}:
let
  cfg = config.host.jellyfin;
  sourceVolume =
    if cfg.media.source == null then
      null
    else
      lib.findFirst (
        volume:
        cfg.media.source == volume.mountPoint || lib.hasPrefix "${volume.mountPoint}/" cfg.media.source
      ) null (builtins.attrValues config.host.storage.volumes);
  sourceMountPoint = if sourceVolume == null then cfg.media.source else sourceVolume.mountPoint;
in
{
  config = lib.mkIf cfg.enable {
    fileSystems.${cfg.media.mountPoint} = {
      device = cfg.media.source;
      fsType = "none";
      options = [
        "bind"
        "nofail"
        "x-systemd.requires-mounts-for=${sourceMountPoint}"
      ]
      ++ lib.optional (
        sourceVolume != null
      ) "x-systemd.wanted-by=${utils.escapeSystemdPath sourceMountPoint}.mount";
    };
  };
}
