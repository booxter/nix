{
  config,
  lib,
  pkgs,
  ...
}:
let
  absolutePath = lib.types.strMatching "^/.*";
in
{
  imports = [
    ./backups.nix
    ./service.nix
    ./web.nix
  ];

  options.host.aurral = {
    enable = lib.mkEnableOption "Aurral music discovery service";

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
      default = "${config.host.aurral.stateDir}/flows";
      description = "Directory where Aurral stores downloaded flows.";
    };

    extraWritePaths = lib.mkOption {
      type = lib.types.listOf absolutePath;
      default = [ ];
      description = "Additional directories Aurral may modify.";
    };

    extraGroups = lib.mkOption {
      type = lib.types.listOf lib.types.nonEmptyStr;
      default = [ ];
      description = "Additional groups assigned to the Aurral service account.";
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
