{ config, ... }:
let
  cfg = config.host.luks.remoteUnlock;
in
{
  assertions = [
    {
      assertion = cfg == null || config.host.disko.layout == "luks";
      message = "host.luks.remoteUnlock requires the LUKS disk layout";
    }
  ];
}
