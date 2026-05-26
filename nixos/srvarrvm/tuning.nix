{
  lib,
  ...
}:
{
  config.host.srvarr.tuning = {
    transmissionNonPreferredLowPriorityRatio = 3.0;
    transmissionNonPreferredPauseRatio = 6.0;
    wgConservativeUploadRateMbit = 8;
  };
}
