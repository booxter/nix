{ config, lib, ... }:
{
  options.host.ups = {
    credentialMode = lib.mkOption {
      type = lib.types.enum [
        "literal"
        "sops"
      ];
      description = "How UPS client and server passwords are provided in this realm.";
    };

    server = {
      enable = lib.mkEnableOption "local UPS server";

      name = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "${lib.strings.toUpper config.networking.hostName}-UPS";
        description = "NUT device name exposed by the local UPS server.";
      };

      description = lib.mkOption {
        type = lib.types.nullOr lib.types.nonEmptyStr;
        default = null;
        description = "Human-readable description of the locally attached UPS.";
      };

    };

    client.server = lib.mkOption {
      type = lib.types.nullOr lib.types.nonEmptyStr;
      default = null;
      description = "Host providing the UPS service monitored by this host.";
    };

    shutdown.waitForLowBattery = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to wait for low battery instead of using a shutdown timer.";
    };
  };
}
