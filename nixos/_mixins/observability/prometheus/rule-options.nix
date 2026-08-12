{ lib, ... }:
{
  options.host.observability.alerts.capacity = {
    cpu = {
      warningPercent = lib.mkOption {
        type = lib.types.ints.between 0 100;
        default = 80;
        description = "CPU utilization percentage that triggers a warning alert.";
      };

      criticalPercent = lib.mkOption {
        type = lib.types.ints.between 0 100;
        default = 90;
        description = "CPU utilization percentage that triggers a critical alert.";
      };
    };

    memory = {
      warningPercent = lib.mkOption {
        type = lib.types.ints.between 0 100;
        default = 80;
        description = "Memory utilization percentage that triggers a warning alert.";
      };

      criticalPercent = lib.mkOption {
        type = lib.types.ints.between 0 100;
        default = 90;
        description = "Memory utilization percentage that triggers a critical alert.";
      };
    };
  };
}
