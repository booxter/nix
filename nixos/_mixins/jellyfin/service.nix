{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.jellyfin;
  loggingConfig = pkgs.writeText "jellyfin-logging.json" (
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
in
{
  config = lib.mkIf cfg.enable {
    services.jellyfin = {
      enable = true;
      package = cfg.package;
    };

    sops.secrets."jellyfin/apiKey" = {
      owner = "root";
      group = "root";
      mode = "0400";
    };

    system.activationScripts.jellyfinLoggingConfig.text = ''
      ${pkgs.coreutils}/bin/install -d -m 0700 -o jellyfin -g jellyfin /var/lib/jellyfin/config
      ${pkgs.coreutils}/bin/install -m 0600 -o jellyfin -g jellyfin ${loggingConfig} /var/lib/jellyfin/config/logging.json
    '';

    users.users.jellyfin.extraGroups = [
      "media"
      "render"
      "video"
    ];

    systemd.services.jellyfin = {
      wantedBy = [ "${utils.escapeSystemdPath cfg.media.mountPoint}.mount" ];
      unitConfig.RequiresMountsFor = cfg.media.mountPoint;
      restartTriggers = [ loggingConfig ];
    };
  };
}
