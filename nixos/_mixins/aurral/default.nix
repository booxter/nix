{
  lib,
  pkgs,
  ...
}:
let
  absolutePath = lib.types.strMatching "^/.*";
  configType = lib.types.submodule (
    { config, ... }:
    {
      options = {
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.callPackage ./package { };
          description = "Aurral package to run.";
        };

        port = lib.mkOption {
          type = lib.types.port;
          default = 3001;
          description = "Loopback HTTP port for Aurral.";
        };

        stateDir = lib.mkOption {
          type = absolutePath;
          default = "/var/lib/aurral";
          description = "Persistent Aurral state directory.";
        };

        flowDir = lib.mkOption {
          type = absolutePath;
          default = "${config.stateDir}/flows";
          description = "Directory where Aurral stores downloaded flows.";
        };

        storage = {
          claim = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "media";
            description = "Storage claim containing Aurral flows.";
          };

          relativePath = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "library/flows";
            description = "Flow directory relative to the selected storage claim.";
          };

          group = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "media";
            description = "Shared storage group for Aurral flows.";
          };
        };

        slskd = {
          package = lib.mkOption {
            type = lib.types.package;
            default = pkgs.slskd;
            description = "slskd package to run.";
          };

          stateDir = lib.mkOption {
            type = absolutePath;
            default = "/var/lib/slskd";
            description = "Persistent slskd state directory.";
          };

          secretPrefix = lib.mkOption {
            type = lib.types.nonEmptyStr;
            default = "slskd";
            description = "SOPS key prefix containing slskd credentials.";
          };

          storage = {
            claim = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = "media";
              description = "Storage claim containing slskd downloads.";
            };

            relativePath = lib.mkOption {
              type = lib.types.nonEmptyStr;
              default = "slskd";
              description = "Directory below the storage claim used by slskd.";
            };
          };

          api.port = lib.mkOption {
            type = lib.types.port;
            default = 5030;
            description = "HTTP API port inside the VPN namespace.";
          };

          vpn = {
            namespace = lib.mkOption {
              type = lib.types.nonEmptyStr;
              description = "VPN namespace containing slskd.";
            };

            peerPort = lib.mkOption {
              type = lib.types.port;
              description = "VPN-provider port forwarded to the Soulseek listener.";
            };
          };

          priority = lib.mkOption {
            type = lib.types.ints.between 1 1000;
            default = 10;
            description = "Aurral source priority assigned to slskd.";
          };

          preferredFormat = lib.mkOption {
            type = lib.types.enum [
              "flac"
              "mp3"
            ];
            default = "flac";
            description = "Audio format Aurral prefers when searching slskd.";
          };

          strictFormat = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Whether Aurral rejects slskd results in other formats.";
          };

          cleanupAfterRuns = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether Aurral removes slskd downloads after processing them.";
          };

          settings = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
            description = "Additional slskd configuration merged into the generated settings.";
          };
        };

        publicHostName = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "Optional public hostname published for Aurral.";
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

        backups.enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether to register the Aurral database for backups.";
        };
      };
    }
  );
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
