{ lib, pkgs, ... }:
{
  options.host.pinepods = {
    enable = lib.mkEnableOption "PinePods podcast server";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package { };
      description = "PinePods bootstrap helper package.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8040;
      description = "Loopback HTTP port for PinePods.";
    };

    publicHostName = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      description = "Public hostname published for PinePods.";
    };

    storage = {
      claim = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "media";
        description = "Storage claim containing downloaded podcasts.";
      };
      relativePath = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "podcasts/pinepods";
        description = "Downloaded podcast directory below the storage claim.";
      };
    };

    sso.application = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "pinepods";
      description = "Realm SSO application controlling PinePods access.";
    };

    auth.standardLogin.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Keep password login available for native and gPodder-compatible clients.";
    };

    integrations = {
      searchApi.url = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "PinePods search API endpoint selected by the deployment.";
      };
      podPeople.url = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "PodPeople directory endpoint selected by the deployment.";
      };
    };

    consoleLogging.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Send supervised PinePods process logs to the container journal.";
    };

    backups = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
      };
      stagingDir = lib.mkOption {
        type = lib.types.strMatching "^/.*";
        default = "/var/lib/pinepods-backup/latest";
      };
    };

    user = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "pinepods";
      internal = true;
    };
    databaseName = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "pinepods";
      internal = true;
    };
    cachePort = lib.mkOption {
      type = lib.types.port;
      default = 6382;
      internal = true;
    };
  };
}
