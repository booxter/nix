{ config, lib, ... }:
let
  cfg = config.host.network.ethernet.disablePauseFrames;
  declaredInterfaces = config.host.network.interfaces;
  isDeclaredEthernet =
    interface:
    builtins.hasAttr interface declaredInterfaces && declaredInterfaces.${interface}.kind == "ethernet";
in
{
  assertions = lib.optionals cfg.enable [
    {
      assertion = cfg.interfaces != [ ];
      message = "host.network.ethernet.disablePauseFrames requires at least one interface";
    }
    {
      assertion = lib.all isDeclaredEthernet cfg.interfaces;
      message = "host.network.ethernet.disablePauseFrames.interfaces must reference declared Ethernet interfaces";
    }
  ];
}
