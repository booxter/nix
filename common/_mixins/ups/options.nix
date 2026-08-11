{ config, lib, ... }:
{
  options.host.ups = {
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

      baseDelaySeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 900;
        description = "Shutdown delay assigned to the UPS server before dependency stages are subtracted.";
      };

      separationSeconds = lib.mkOption {
        type = lib.types.ints.positive;
        default = 150;
        description = "Seconds separating each shutdown dependency stage.";
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
