{ config, ... }:
let
  cfg = config.host.network;
in
{
  assertions = [
    {
      assertion = cfg.primaryInterface == null || builtins.hasAttr cfg.primaryInterface cfg.interfaces;
      message = "host.network.primaryInterface must reference a declared host.network.interfaces entry";
    }
  ];
}
