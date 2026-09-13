{
  apiKeySecret ? null,
  extraOptions ? { },
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
  apiKeyEnvironment = "${name}-api-key.env";
in
{
  options.host.${name} = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          stateDir = lib.mkOption {
            type = lib.types.strMatching "^/.+";
            default = "/var/lib/${name}";
          };
        }
        // extraOptions;
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
          auth.policy = "media-admin";
        };

        host.web.api.${name} = {
          service = name;
          interface = name;
          localUnit = "${name}.service";
          allowedCidrs = [ "${config.host.network.ipAddress}/32" ];
          authentication.apiKey =
            if apiKeySecret == null then
              {
                source = "${cfg.stateDir}/config.xml";
                format = "xml-element";
                field = "ApiKey";
              }
            else
              {
                source = config.sops.secrets.${apiKeySecret}.path;
                format = "raw";
              };
        };

        host.backups.sources.${name} = {
          title = lib.strings.toSentenceCase name;
          paths = [ "${cfg.stateDir}/Backups" ];
        };
      }
      (lib.mkIf (apiKeySecret != null) {
        sops.secrets.${apiKeySecret} = { };

        sops.templates.${apiKeyEnvironment} = {
          content = ''
            ${lib.toUpper name}__AUTH__APIKEY=${config.sops.placeholder.${apiKeySecret}}
          '';
          restartUnits = [ "${name}.service" ];
        };

        services.${name}.environmentFiles = [ config.sops.templates.${apiKeyEnvironment}.path ];
      })
      (lib.optionalAttrs media {
        services.${name} = {
          user = name;
          group = "media";
        };

        host.storage.claims.media.attachments.${name} = { };

        systemd.services.${name}.serviceConfig.UMask = lib.mkForce "0002";

        users.users.${name}.isSystemUser = true;
      })
    ]
  );
}
