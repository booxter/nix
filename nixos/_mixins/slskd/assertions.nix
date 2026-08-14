{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  inherit (model) resolved;
in
{
  assertions = lib.optionals (resolved != null) [
    {
      assertion = builtins.hasAttr resolved.user config.host.storage.identities.users;
      message = "The slskd user must reference a shared storage identity.";
    }
    {
      assertion = builtins.hasAttr resolved.group config.host.storage.identities.groups;
      message = "The slskd group must reference a shared storage identity.";
    }
    {
      assertion = resolved.claim != null;
      message = "host.aurral.slskd.storage.claim must reference a storage claim.";
    }
    {
      assertion = resolved.namespace != null;
      message = "host.aurral.slskd.vpn.namespace must reference a VPN namespace.";
    }
  ];
}
