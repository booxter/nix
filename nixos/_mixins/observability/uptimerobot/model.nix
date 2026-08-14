{
  config,
  lib,
  outputs,
}:
let
  cfg = config.host.observability.uptimeRobot.controller;
  fleetServices = import ../../../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  planner = import ../../../_lib/external-probe-planner.nix { inherit lib; };
  plan =
    if cfg.enable then
      planner {
        capacity = 10;
        minimumImportance = "best-effort";
        spreadByOwner = true;
        candidates = fleetServices.public;
      }
    else
      {
        selected = [ ];
        selectedIds = [ ];
        omitted = [ ];
        requiredOverflow = false;
      };
in
{
  inherit plan;
}
