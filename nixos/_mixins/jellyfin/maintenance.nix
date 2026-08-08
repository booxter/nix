{
  config,
  lib,
  utils,
  ...
}:
let
  jellyfinCfg = config.services.jellyfin;
  cfg = jellyfinCfg.maintenance;
  waitForIdleCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' cfg.package "wait-for-jellyfin-idle")
    "--url"
    cfg.jellyfinUrl
    "--api-key-file"
    jellyfinCfg.apiKey.file
  ];
in
{
  options.services.jellyfin.maintenance = {
    enable = lib.mkEnableOption "playback-aware system maintenance";

    package = lib.mkOption {
      type = lib.types.package;
      description = "Package providing the Jellyfin maintenance helper.";
    };

    jellyfinUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8096";
      description = "Jellyfin API URL checked for active playback.";
    };

    gateSystemSwitch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether system switches should wait for Jellyfin to become idle.";
    };

    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Systemd services that should wait for Jellyfin to become idle.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = jellyfinCfg.enable;
        message = "services.jellyfin.maintenance requires services.jellyfin.enable.";
      }
    ];

    # Check again at activation so playback cannot begin during a preceding build.
    system.preSwitchChecks.jellyfinPlayback = lib.mkIf cfg.gateSystemSwitch ''
      if [ "''${2-}" = switch ]; then
        ${waitForIdleCommand}
      fi
    '';

    # Checking before maintenance also avoids starting expensive work while busy.
    systemd.services = lib.genAttrs cfg.units (_: {
      serviceConfig = {
        ExecStartPre = [ waitForIdleCommand ];
        TimeoutStartSec = "infinity";
      };
    });
  };
}
