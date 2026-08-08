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
    wgConservativeUploadRateMbit = 8;
  };
}
