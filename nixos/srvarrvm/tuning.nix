{
  lib,
  ...
}:
{
  options.host.srvarrTuning = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    readOnly = true;
    description = "Shared srvarr tuning constants consumed across multiple modules.";
  };

  config.host.srvarrTuning = {
    transmissionNonPreferredLowPriorityRatio = 3.0;
    transmissionNonPreferredPauseRatio = 6.0;
    wgConservativeUploadRateMbit = 8;
  };
}
