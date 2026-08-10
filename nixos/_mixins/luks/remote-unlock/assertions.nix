{ config, ... }:
let
  cfg = config.host.luks.remoteUnlock;
in
{
  assertions = [
    {
      assertion = !cfg.enable || config.host.luks.enable;
      message = "host.luks.remoteUnlock requires host.luks.enable";
    }
    {
      assertion = !cfg.enable || cfg.networkInterface != null;
      message = "host.luks.remoteUnlock requires a networkInterface";
    }
    {
      assertion = !cfg.enable || cfg.authorizedKeys != [ ];
      message = "host.luks.remoteUnlock requires at least one authorized key";
    }
  ];
}
