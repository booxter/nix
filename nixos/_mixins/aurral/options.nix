{
  lib,
  ...
}:
let
  absolutePath = lib.types.strMatching "^/.*";
  configType = lib.types.submodule {
    options = {
      stateDir = lib.mkOption {
        type = absolutePath;
        default = "/var/lib/aurral";
        description = "Persistent Aurral state directory.";
      };

      storageClaim = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Storage claim containing Aurral flows and slskd downloads.";
      };

      slskd = {
        vpnNamespace = lib.mkOption {
          type = lib.types.nonEmptyStr;
          description = "VPN namespace containing slskd.";
        };

        peerPort = lib.mkOption {
          type = lib.types.port;
          description = "VPN-provider port forwarded to the Soulseek listener.";
        };
      };

      publicHostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Public hostname published for Aurral.";
      };

    };
  };
in
{
  options.host.aurral = lib.mkOption {
    type = with lib.types; nullOr configType;
    default = null;
    description = "Aurral music discovery service.";
  };
}
