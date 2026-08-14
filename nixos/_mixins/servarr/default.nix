{
  addUserToApiGroup ? true,
  apiGroup,
  name,
}:
{
  config,
  lib,
  ...
}:
let
  cfg = config.host.${name};
  serviceCfg = config.services.${name};
in
{
  options.host.${name} = {
    enable = lib.mkEnableOption "${name} media manager";

    stateDir = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "/var/lib/${name}";
    };

    storage.claim = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "media";
    };

    port = lib.mkOption {
      type = lib.types.port;
      readOnly = true;
      internal = true;
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = name;
      internal = true;
    };

    group = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "media";
      internal = true;
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.storage.claim config.host.storage.claims;
        message = "host.${name}.storage.claim must select a known storage claim";
      }
    ];

    host.${name}.port = serviceCfg.settings.server.port;

    services.${name} = {
      enable = true;
      dataDir = cfg.stateDir;
      user = cfg.user;
      group = cfg.group;
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

    host.web.services.${name} = {
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

    host.web.api.${name} = {
      service = name;
      interface = name;
      localUnit = "${name}.service";
      allowedCidrs = [ "${config.host.network.ipAddress}/32" ];
      authentication.apiKey = {
        source = "${cfg.stateDir}/config.xml";
        field = "ApiKey";
      };
    };

    host.storage.claims.${cfg.storage.claim}.attachments.${name}.unit = name;

    host.backups.sources.${name} = {
      title = lib.strings.toSentenceCase name;
      paths = [ "${cfg.stateDir}/Backups" ];
    };

    systemd.services.${name}.serviceConfig.UMask = lib.mkForce "0002";

    users.groups.${apiGroup} = { };
    users.users.${cfg.user} = {
      isSystemUser = true;
      extraGroups = lib.optional addUserToApiGroup apiGroup;
    };
  };
}
