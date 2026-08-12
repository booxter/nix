{ config, ... }:
let
  capacity = config.host.observability.alerts.capacity;
in
{
  assertions = [
    {
      assertion = capacity.cpu.warningPercent < capacity.cpu.criticalPercent;
      message = "CPU capacity warning threshold must be below the critical threshold.";
    }
    {
      assertion = capacity.memory.warningPercent < capacity.memory.criticalPercent;
      message = "memory capacity warning threshold must be below the critical threshold.";
    }
  ];
}
