{ config, lib, ... }:
let
  cfg = config.host.remote-control.server.vnc;
in
{
  assertions = lib.optionals cfg.enable [
    {
      assertion = config.host.hardware.drmCard != null;
      message = "VNC remote control requires host.hardware.drmCard";
    }
    {
      assertion = config.host.hardware.displayMode != null;
      message = "VNC remote control requires host.hardware.displayMode";
    }
    {
      assertion = config.host.hardware.scale != null;
      message = "VNC remote control requires host.hardware.scale";
    }
    {
      assertion = config.host.hardware.displays != [ ];
      message = "VNC remote control requires at least one host.hardware.displays entry";
    }
  ];
}
