{
  config,
  lib,
  ...
}:
let
  cfg = config.host.prowlarr;
in
{
  options.host.prowlarr = {
    enable = lib.mkEnableOption "Prowlarr indexer manager";

    stateDir = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "/var/lib/prowlarr";
    };

    port = lib.mkOption {
      type = lib.types.port;
      readOnly = true;
      internal = true;
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "prowlarr";
      internal = true;
    };

    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "prowlarr";
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable {
    host.prowlarr.port = config.services.prowlarr.settings.server.port;

    services.prowlarr = {
      enable = true;
      settings = {
        auth = {
          method = "External";
          required = "Enabled";
        };
        log.analyticsEnabled = false;
        server.bindaddress = "127.0.0.1";
        update = {
          automatically = false;
          mechanism = "external";
        };
      };
    };

    host.web.services.prowlarr = {
      enable = true;
      upstream = "http://127.0.0.1:${toString cfg.port}";
      health = {
        frontend = {
          enable = true;
          path = "/oauth2/sign_in";
        };
        backend = {
          enable = true;
          path = "/ping";
        };
      };
      dashboard = {
        enable = true;
        section = "media-admin";
      };
      auth.policy = "media-admin";
    };

    host.web.api.prowlarr = {
      service = "prowlarr";
      interface = "prowlarr";
      localUnit = "prowlarr.service";
      allowedCidrs = [ "${config.host.network.ipAddress}/32" ];
      authentication.apiKey = {
        source = "${cfg.stateDir}/config.xml";
        field = "ApiKey";
      };
    };

    host.backups.sources.prowlarr = {
      title = "Prowlarr";
      paths = [ "${cfg.stateDir}/Backups" ];
    };

    systemd.tmpfiles.rules = [
      "d '${cfg.stateDir}' 0700 ${cfg.user} root - -"
    ];

    systemd.services.prowlarr = {
      unitConfig = {
        Wants = [ "network-online.target" ];
        After = [ "network-online.target" ];
      };
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        ExecStart = lib.mkForce "${config.services.prowlarr.package}/bin/Prowlarr -nobrowser -data=${cfg.stateDir}";
        ReadWritePaths = [ cfg.stateDir ];
      };
    };

    users.groups.${cfg.group} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = "/var/empty";
    };
  };
}
