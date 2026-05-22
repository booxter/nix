{ pkgs, ... }:
let
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
in
{
  services.jellyfin = {
    enable = true;
    openFirewall = true;
  };

  system.activationScripts.jellyfinLoggingConfig.text = ''
    ${pkgs.coreutils}/bin/install -d -m 0700 -o jellyfin -g jellyfin /var/lib/jellyfin/config
    ${pkgs.coreutils}/bin/install -m 0600 -o jellyfin -g jellyfin ${jellyfinLoggingConfig} /var/lib/jellyfin/config/logging.json
  '';

  users.users.jellyfin.extraGroups = [ "media" ];

  systemd.services.jellyfin.unitConfig.RequiresMountsFor = "/media";
  systemd.services.jellyfin.restartTriggers = [ jellyfinLoggingConfig ];

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
}
