{
  media ? true,
  name,
}:
{
  config,
  lib,
  ...
}:
let
  cfg = config.host.${name};
  port = config.services.${name}.settings.server.port;
in
{
  options.host.${name} = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          stateDir = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "/var/lib/${name}";
          };
        }
        // lib.optionalAttrs media {
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
      }
    );
    default = null;
    description = "${name} service configuration.";
  };

  config = lib.mkIf (cfg != null) (
    lib.mkMerge [
      {
        services.${name} = {
          enable = true;
          dataDir = cfg.stateDir;
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
          upstream = "http://127.0.0.1:${toString port}";
          health = {
            frontend = {
              path = "/oauth2/sign_in";
            };
            backend = {
              path = "/ping";
            };
          };
          dashboard = {
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

        host.backups.sources.${name} = {
          title = lib.strings.toSentenceCase name;
          paths = [ "${cfg.stateDir}/Backups" ];
        };
      }
      (lib.optionalAttrs media {
        services.${name} = {
          user = cfg.user;
          group = cfg.group;
        };

        host.storage.claims.media.attachments.${name} = { };

        systemd.services.${name}.serviceConfig.UMask = lib.mkForce "0002";

        users.users.${cfg.user}.isSystemUser = true;
      })
    ]
  );
}
