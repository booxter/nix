{ config, lib, ... }:
let
  cfg = config.host.observability.lanWan;
  override = cfg.wanEgressOverride;
in
{
  assertions = lib.optionals cfg.enable [
    {
      assertion = override == null || cfg.interface != null;
      message = "host.observability.lanWan.wanEgressOverride requires host.observability.lanWan.interface.";
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
