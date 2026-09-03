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
        options.stateDir = lib.mkOption {
          type = lib.types.strMatching "^/.+";
          default = "/var/lib/${name}";
        };

        options.agent = {
          enable = lib.mkEnableOption "experimental ${name} Hermes Agent";
          shadow = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Run the ${name} agent and validate its output without importing it.";
          };
          providerHost = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = "NixOS host providing Ollama inference to the ${name} agent.";
          };
          model = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = "Ollama model used by the ${name} agent.";
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
