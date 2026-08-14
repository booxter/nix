{ config, lib, ... }:
{
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

    certificateDnsNames = lib.mkOption {
      type = with lib.types; nonEmptyListOf nonEmptyStr;
      default = [
        config.networking.hostName
        "${config.networking.hostName}.${config.host.network.lanDomain}"
        "${config.networking.hostName}.local"
      ];
      description = "Default DNS identities included in host service certificates.";
    };

    interfaces = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            kind = lib.mkOption {
              type = lib.types.enum [
                "ethernet"
                "wireless"
              ];
              default = "ethernet";
              description = "Network interface kind.";
            };

            disablePauseFrames = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = "Whether to disable Ethernet pause-frame negotiation.";
            };
          };
        }
      );
      default = { };
      description = "Host network interfaces declared for shared network policy.";
    };

    primaryInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default =
        let
          interfaces = builtins.attrNames config.host.network.interfaces;
        in
        if builtins.length interfaces == 1 then builtins.head interfaces else null;
      description = "Declared interface used as the primary interface for host services.";
    };

  };

  config.assertions = [
    {
      assertion =
        config.host.network.primaryInterface == null
        || builtins.hasAttr config.host.network.primaryInterface config.host.network.interfaces;
      message = "host.network.primaryInterface must reference a declared host.network.interfaces entry";
    }
  ];
}
