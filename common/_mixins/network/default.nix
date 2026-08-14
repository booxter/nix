{ config, lib, ... }:
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
      default = null;
      description = "Declared interface used as the primary interface for host services.";
    };

  };
}
