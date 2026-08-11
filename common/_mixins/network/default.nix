{ lib, ... }:
{
  imports = [ ./assertions.nix ];

  options.host.network = {
    lanDomain = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "home.arpa";
      description = "Local network DNS domain.";
    };

    publicDomain = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "ihar.dev";
      description = "Public DNS domain used for internet-facing services.";
    };

    interfaces = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.kind = lib.mkOption {
            type = lib.types.enum [
              "ethernet"
              "wireless"
            ];
            description = "Network interface kind.";
          };
        }
      );
      default = { };
      description = "Host network interfaces declared for shared network policy.";
    };

    primaryInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Declared interface used as the primary interface for host services.";
    };

  };
}
