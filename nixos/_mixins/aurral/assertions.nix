{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) cfg selected;
in
{
  config.assertions = lib.optionals cfg.slskd.enable [
    {
      assertion = cfg.enable;
      message = "host.aurral.slskd.enable requires host.aurral.enable";
    }
    {
      assertion = cfg.slskd.instance != null;
      message = "host.aurral.slskd.instance must select a host-local slskd instance";
    }
    {
      assertion = selected != null;
      message = "host.aurral.slskd.instance must name an enabled host.slskd.instances entry";
    }
  ];
}
