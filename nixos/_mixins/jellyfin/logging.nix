{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.jellyfin;
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
  options.services.jellyfin.logging.playbackDebug =
    lib.mkEnableOption "Jellyfin playback debug logging";

  config = lib.mkIf (cfg.enable && cfg.logging.playbackDebug) {
    system.activationScripts.jellyfinLoggingConfig.text = ''
      ${pkgs.coreutils}/bin/install -d -m 0700 -o ${cfg.user} -g ${cfg.group} ${cfg.configDir}
      ${pkgs.coreutils}/bin/install -m 0600 -o ${cfg.user} -g ${cfg.group} ${loggingConfig} ${cfg.configDir}/logging.json
    '';

    systemd.services.jellyfin.restartTriggers = [ loggingConfig ];
  };
}
