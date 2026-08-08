{
  config,
  lib,
  utils,
  ...
}:
let
  jellyfinCfg = config.services.jellyfin;
  cfg = jellyfinCfg.mediaMount;
  targetMountUnit = "${utils.escapeSystemdPath cfg.target}.mount";
  sourceMountUnit = "${utils.escapeSystemdPath cfg.sourceMount}.mount";
in
{
  options.services.jellyfin.mediaMount = {
    enable = lib.mkEnableOption "a bind-mounted Jellyfin media tree";

    source = lib.mkOption {
      type = lib.types.path;
      description = "Source directory containing Jellyfin media.";
    };

    sourceMount = lib.mkOption {
      type = lib.types.path;
      description = "Filesystem mount containing the media source directory.";
    };

    target = lib.mkOption {
      type = lib.types.path;
      default = "/media";
      description = "Path at which Jellyfin expects its media tree.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = jellyfinCfg.enable;
        message = "services.jellyfin.mediaMount requires services.jellyfin.enable.";
      }
    ];

    systemd.services.jellyfin = {
      # If the source volume mounts late, start Jellyfin with the bind mount
      # instead of leaving its reverse proxy with a dead upstream.
      wantedBy = [ targetMountUnit ];
      unitConfig.RequiresMountsFor = cfg.target;
    };

    fileSystems.${cfg.target} = {
      device = cfg.source;
      fsType = "none";
      options = [
        "bind"
        "nofail"
        "x-systemd.requires-mounts-for=${cfg.sourceMount}"
        "x-systemd.wanted-by=${sourceMountUnit}"
      ];
    };
  };
}
