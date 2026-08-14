{
  lib,
  pkgs,
  ...
}:
let
  instanceType = lib.types.submodule (
    { config, name, ... }:
    {
      options = {
        port = lib.mkOption {
          type = lib.types.port;
          description = "Loopback HTTP port for this Glance instance.";
        };

        sections = lib.mkOption {
          type = lib.types.listOf (
            lib.types.submodule {
              options = {
                id = lib.mkOption {
                  type = lib.types.nonEmptyStr;
                  description = "Dashboard catalog section identifier.";
                };

                title = lib.mkOption {
                  type = lib.types.nonEmptyStr;
                  description = "Heading shown for this dashboard section.";
                };
              };
            }
          );
          default = [ ];
          description = "Ordered catalog sections displayed by this instance.";
        };

        unitName = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "glance-${name}";
          readOnly = true;
          internal = true;
          description = "Systemd unit name for this Glance instance.";
        };

        upstream = lib.mkOption {
          type = lib.types.nonEmptyStr;
          default = "http://127.0.0.1:${toString config.port}";
          readOnly = true;
          internal = true;
          description = "Loopback HTTP origin for this Glance instance.";
        };
      };
    }
  );
in
{
  options.host.glance = {
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.glance;
      description = "Glance package used by all instances on this host.";
    };

    instances = lib.mkOption {
      type = lib.types.attrsOf instanceType;
      default = { };
      description = "Glance dashboard instances named by catalog exposure scope.";
    };

    search.provider = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Site search provider used by Glance dashboards.";
    };
  };
}
