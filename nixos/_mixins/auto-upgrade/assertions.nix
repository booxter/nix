{
  config,
  fleetInventory,
  lib,
  outputs,
  ...
}:
let
  isoDatePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$";
  model = import ./model.nix {
    inherit
      config
      fleetInventory
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
  ]
  ++ lib.concatMap (hold: [
    {
      assertion = builtins.match isoDatePattern hold.startDate != null;
      message = "host.autoUpgrade.holds startDate `${hold.startDate}` must use YYYY-MM-DD.";
    }
    {
      assertion = builtins.match isoDatePattern hold.stopDate != null;
      message = "host.autoUpgrade.holds stopDate `${hold.stopDate}` must use YYYY-MM-DD.";
    }
    {
      assertion = hold.startDate <= hold.stopDate;
      message = "host.autoUpgrade.holds range `${hold.startDate}..${hold.stopDate}` must not end before it starts.";
    }
  ]) config.host.autoUpgrade.holds;
}
