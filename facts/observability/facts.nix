# Fleet-wide observability alert thresholds.
{
  capacity = {
    cpu = {
      warningPercent = 80;
      criticalPercent = 90;
    };
    memory = {
      warningPercent = 80;
      criticalPercent = 90;
    };
    hypervisorMemory = {
      warningAvailableGiB = 16;
      warningPercent = 90;
      criticalAvailableGiB = 8;
      criticalPercent = 95;
    };
  };
}
