{ config, lib, ... }:
let
  endpointType = lib.types.submodule {
    options = {
      url = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "URL opened from the dashboard.";
      };

      checkUrl = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Optional URL used to check entry availability.";
      };
    };
  };
in
{
  options.host.dashboard.entries = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            title = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = lib.strings.toSentenceCase name;
              description = "Human-readable dashboard entry title.";
            };

            icon = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = "sh:${name}";
              description = "Dashboard icon identifier or URL.";
            };

            section = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "Dashboard section containing this entry.";
            };

            endpoints = {
              internal = lib.mkOption {
                type = with lib.types; nullOr endpointType;
                default = null;
                description = "Entry endpoint available from the trusted network.";
              };

              public = lib.mkOption {
                type = with lib.types; nullOr endpointType;
                default = null;
                description = "Entry endpoint safe to publish on an external dashboard.";
              };
            };
          };
        }
      )
    );
    default = { };
    description = "Non-web resources contributed to the fleet dashboard catalog.";
  };

  config.assertions = lib.mapAttrsToList (name: entry: {
    assertion = entry.endpoints.internal != null || entry.endpoints.public != null;
    message = "host.dashboard.entries.${name} requires at least one endpoint";
  }) config.host.dashboard.entries;
}
