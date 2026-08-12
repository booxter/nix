{ lib, ... }:
{
  options.host.ups.scheduler = {
    enable = lib.mkEnableOption "UPS shutdown scheduling";

    waitForLowBattery = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to wait for a low-battery event before shutting down.";
    };

    shutdownDelaySeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Seconds to remain on battery before shutting down.";
    };
  };
}
