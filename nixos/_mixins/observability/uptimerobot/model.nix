{
  config,
  lib,
  outputs,
}:
let
  localHost = config.networking.hostName;
  cfg = config.host.observability.uptimeRobot.controller;
  otherConfigurations = builtins.removeAttrs outputs.nixosConfigurations [ localHost ];
  controllerHosts = builtins.attrNames (
    lib.filterAttrs (_: enabled: enabled) (
      lib.mapAttrs (
        _: configuration: configuration.config.host.observability.uptimeRobot.controller.enable
      ) otherConfigurations
      // {
        ${localHost} = cfg.enable;
      }
    )
  );
  fleetServices = import ../../../_lib/fleet-web-services.nix {
    inherit config lib outputs;
  };
  planner = import ../../../_lib/external-probe-planner.nix { inherit lib; };
  plan =
    if cfg.enable then
      planner {
        inherit (cfg) capacity;
        inherit (cfg.planner) minimumImportance spreadByOwner;
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
  inherit controllerHosts plan;
}
