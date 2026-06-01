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
  };

  system.activationScripts.jellyfinLoggingConfig.text = ''
    ${pkgs.coreutils}/bin/install -d -m 0700 -o jellyfin -g jellyfin /var/lib/jellyfin/config
    ${pkgs.coreutils}/bin/install -m 0600 -o jellyfin -g jellyfin ${jellyfinLoggingConfig} /var/lib/jellyfin/config/logging.json
  '';

  users.users.jellyfin.extraGroups = [ "media" ];

  systemd.services.jellyfin = {
    # If /volume2 is slow during boot and /media mounts later, bring Jellyfin
    # back with the media bind mount instead of leaving nginx with a dead
    # upstream.
    wantedBy = [ "media.mount" ];
    unitConfig.RequiresMountsFor = "/media";
    restartTriggers = [ jellyfinLoggingConfig ];
  };

  # Keep the existing /media path expected by Jellyfin/Jellarr.
  fileSystems."/media" = {
    device = "/volume2/Media";
    fsType = "none";
    options = [
      "bind"
      "nofail"
      "x-systemd.requires-mounts-for=/volume2"
      "x-systemd.wanted-by=volume2.mount"
    ];
  };
}
