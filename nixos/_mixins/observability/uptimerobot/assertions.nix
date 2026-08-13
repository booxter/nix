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
  cfg = config.host.observability.uptimeRobot.controller;
in
{
  assertions = [
    {
      assertion = builtins.length model.controllerHosts <= 1;
      message = "The fleet has multiple UptimeRobot controllers: ${lib.concatStringsSep ", " model.controllerHosts}";
    }
    {
      assertion = !cfg.enable || config.nixpkgs.hostPlatform.isLinux;
      message = "The UptimeRobot controller requires NixOS.";
    }
    {
      assertion = !model.plan.requiredOverflow;
      message = "Required external probes exceed UptimeRobot capacity ${toString cfg.capacity}.";
    }
  ];
}
