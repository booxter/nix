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

      authProxy = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether Aurral trusts authentication from its local reverse proxy.";
        };

        adminGroups = lib.mkOption {
          type = lib.types.listOf lib.types.nonEmptyStr;
          default = [ ];
          description = "SSO groups whose members receive Aurral administrator access.";
        };

        allowedGroups = lib.mkOption {
          type = lib.types.listOf lib.types.nonEmptyStr;
          default = [
            "media-admins"
            "media-users"
          ];
          description = "SSO groups allowed to access Aurral.";
        };
      };
    };
  };
in
{
  imports = [
    ../slskd/assertions.nix
    ../slskd/service.nix
    ./assertions.nix
    ./backups.nix
    ./service.nix
    ./web.nix
  ];

  options.host.aurral = lib.mkOption {
    type = with lib.types; nullOr configType;
    default = null;
    description = "Aurral music discovery service.";
  };
}
