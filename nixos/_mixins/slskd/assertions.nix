{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) resolved;
in
{
  assertions = lib.optionals (resolved != null) [
    {
      assertion = resolved.namespace != null;
      message = "host.aurral.slskd.vpnNamespace must reference a VPN namespace.";
    }
  ];
}
