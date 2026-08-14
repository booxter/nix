{ config, lib, ... }:
let
  cfg = config.host.observability.lanWan;
  override = cfg.wanEgressOverride;
in
{
  assertions = lib.optionals config.host.observability.enable [
    {
      assertion = override == null || config.host.network.primaryInterface != null;
      message = "host.observability.lanWan.wanEgressOverride requires a primary network interface.";
    }
    {
      assertion =
        override == null
        || !(builtins.elem override.name [
          "lan"
          "wan"
          "wan_other"
        ]);
      message = "host.observability.lanWan.wanEgressOverride.name conflicts with a reserved counter name.";
    }
  ];
}
