{ config, ... }:
let
  cfg = config.host.luks.remoteUnlock;
in
{
  assertions = [
    {
      assertion = cfg == null || config.host.luks.enable;
      message = "host.luks.remoteUnlock requires host.luks.enable";
    }
  ];
}
