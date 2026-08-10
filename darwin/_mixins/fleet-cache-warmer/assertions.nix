{ config, lib, ... }:
let
  cfg = config.host.fleetCacheWarmer;
in
{
  assertions = lib.optional cfg.enable {
    assertion = !cfg.pushToAttic || config.host.attic.realmServers != { };
    message = "fleet cache warming cannot push because the realm has no Attic servers";
  };
}
