{
  config,
  lib,
  outputs,
  ...
}:
let
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
in
{
  assertions = [
    {
      assertion = model.unknownExclusionHosts == [ ];
      message = "auto-upgrade exclusions name unknown or out-of-realm hosts: ${lib.concatStringsSep ", " model.unknownExclusionHosts}";
    }
    {
      assertion = model.weekdayConflicts == [ ];
      message = lib.concatStringsSep "; " model.weekdayConflicts;
    }
    {
      assertion = model.failures == [ ];
      message = lib.concatStringsSep "; " model.failures;
    }
  ];
}
