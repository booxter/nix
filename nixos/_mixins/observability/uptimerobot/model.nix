{
  config,
  fleetWebServices,
  lib,
}:
let
  cfg = config.host.observability.uptimeRobot.controller;
  planner = import ../../../_lib/external-probe-planner.nix { inherit lib; };
  plan =
    if cfg.enable then
      planner {
        capacity = 10;
        minimumImportance = "best-effort";
        spreadByOwner = true;
        candidates = fleetWebServices.public;
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
