{ config, lib, ... }:
let
  model = import ./model.nix { inherit config; };
  inherit (model) cfg;
  slskd = model.slskd.resolved;
in
{
  config.assertions = lib.optionals (cfg != null) [
    {
      assertion = model.storageClaim != null;
      message = "host.aurral.storageClaim must name a host storage claim";
    }
    {
      assertion = model.ssoApplication != null;
      message = "Aurral requires its realm SSO application";
    }
    {
      assertion = slskd.namespace != null;
      message = "host.aurral.slskd.vpnNamespace must reference a VPN namespace.";
    }
  ];
}
