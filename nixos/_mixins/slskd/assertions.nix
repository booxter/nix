{ config, lib, ... }:
let
  model = import ./model.nix { inherit config lib; };
  unique = values: builtins.length values == builtins.length (lib.unique values);
in
{
  assertions = [
    {
      assertion = model.enabled == { } || builtins.hasAttr model.cfg.user config.host.accounts.users;
      message = "host.slskd.user must reference a managed host account.";
    }
    {
      assertion = model.enabled == { } || builtins.hasAttr model.cfg.group config.host.accounts.groups;
      message = "host.slskd.group must reference a managed host group.";
    }
    {
      assertion = unique model.apiBindings;
      message = "Enabled slskd instances must use unique API ports within each VPN namespace.";
    }
    {
      assertion = unique model.peerBindings;
      message = "Enabled slskd instances must use unique forwarded peer ports within each VPN namespace.";
    }
    {
      assertion = unique model.secretPrefixes;
      message = "Enabled slskd instances must use unique secret prefixes.";
    }
    {
      assertion = unique model.stateDirs;
      message = "Enabled slskd instances must use unique state directories.";
    }
    {
      assertion = unique model.storageRoots;
      message = "Enabled slskd instances must use unique storage roots.";
    }
  ]
  ++ lib.mapAttrsToList (name: instance: {
    assertion = instance.claim != null;
    message = "host.slskd.instances.${name} references unknown storage claim '${instance.storage.claim}'.";
  }) model.resolved
  ++ lib.mapAttrsToList (name: instance: {
    assertion = instance.namespace != null;
    message = "host.slskd.instances.${name} references unknown VPN namespace '${instance.vpn.namespace}'.";
  }) model.resolved;
}
