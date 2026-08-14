{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.watchstate;
  image = import ../../_lib/oci-image.nix {
    image = cfg.container;
    inherit pkgs;
  };
  uid = 296;
in
{
  config = lib.mkIf (cfg.enable && config.host.jellyfin != null) {
    users.groups.watchstate.gid = uid;
    users.users.watchstate = {
      description = "WatchState service user";
      isSystemUser = true;
      group = "watchstate";
      inherit uid;
      home = cfg.dataDirectory;
      createHome = false;
    };

    virtualisation.oci-containers = {
      backend = "podman";
      containers.watchstate = {
        image = image.ref;
        imageFile = image.imageFile;
        pull = "never";
        user = "${toString uid}:${toString uid}";
        environment = {
          TZ = config.host.site.timeZone;
          WS_TRUST_LOCAL = "true";
          WS_CRON_IMPORT = "true";
          WS_CRON_IMPORT_AT = "0 */12 * * *";
          WS_CRON_EXPORT = "true";
          WS_CRON_EXPORT_AT = "30 */12 * * *";
          WS_CRON_MEDIA_HEALTH = "true";
          WS_CRON_MEDIA_HEALTH_AT = "0 5 * * *";
          WS_MEDIA_HEALTH_CHECK_FILES = "true";
          WS_CRON_BACKUP = "false";
          WS_HTTP_SYNC_REQUESTS = "true";
        };
        environmentFiles = [ "/run/watchstate-auth/auth.env" ];
        extraOptions = [
          "--cap-drop=all"
          "--no-healthcheck"
          "--security-opt=no-new-privileges"
        ];
        ports = [ "127.0.0.1:${toString cfg.port}:${toString cfg.port}" ];
        volumes = [
          "${cfg.dataDirectory}:/config:rw"
          "${cfg.library.source}:${cfg.library.mountPoint}:ro"
        ];
      };
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDirectory} 0700 watchstate watchstate - -"
    ];

    systemd.services.podman-watchstate = {
      requires = [ "watchstate-password-env.service" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "watchstate-password-env.service"
      ];
      unitConfig.RequiresMountsFor = [
        cfg.dataDirectory
        cfg.library.source
      ];
    };
  };
}
