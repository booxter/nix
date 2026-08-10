{
  config,
  facts,
  pkgs,
  ...
}:
let
  jellyfinPort = 8096;
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
  host.web.services.jellyfin = {
    enable = true;
    internal.enable = false;
    public = {
      enable = true;
      hostName = "jf.${config.host.network.publicDomain}";
      transport = "direct";
      directUpstream = "http://127.0.0.1:${toString jellyfinPort}";
    };
    health.frontend = {
      enable = true;
      path = "/web/";
    };
    presentation.dashboard = {
      enable = true;
      category = "user";
    };
  };

  services.jellyfin = {
    enable = true;
  };

  system.activationScripts.jellyfinLoggingConfig.text = ''
    ${pkgs.coreutils}/bin/install -d -m 0700 -o jellyfin -g jellyfin /var/lib/jellyfin/config
    ${pkgs.coreutils}/bin/install -m 0600 -o jellyfin -g jellyfin ${jellyfinLoggingConfig} /var/lib/jellyfin/config/logging.json
  '';

  users.users.jellyfin.extraGroups = [
    "media"
    "render"
    "video"
  ];

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
    device = facts.shared-storage.resources.media.path;
    fsType = "none";
    options = [
      "bind"
      "nofail"
      "x-systemd.requires-mounts-for=/volume2"
      "x-systemd.wanted-by=volume2.mount"
    ];
  };
}
