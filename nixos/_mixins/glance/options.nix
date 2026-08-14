{ lib, ... }:
let
  instanceType = lib.types.submodule {
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
    };
  };
in
{
  options.host.glance = {
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
