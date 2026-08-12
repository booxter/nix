{ config, lib }:
let
  cfg = config.host.slskd;
  enabled = lib.filterAttrs (_: instance: instance.enable) cfg.instances;
  resolve =
    name: instance:
    let
      claim = config.host.storage.claims.${instance.storage.claim} or null;
      namespace = config.host.vpn.namespaces.${instance.vpn.namespace} or null;
      rootDir = if claim == null then null else "${claim.mountPoint}/${instance.storage.relativePath}";
    in
    instance
    // {
      inherit (cfg) group user;
      inherit
        claim
        name
        namespace
        rootDir
        ;
      unitName = "slskd-${name}";
      vpnClientName = "slskd-${name}";
      incompleteDir = if rootDir == null then null else "${rootDir}/incomplete";
      completedDir = if rootDir == null then null else "${rootDir}/complete";
      apiUrl =
        if namespace == null then
          null
        else
          "http://${namespace.namespaceAddress}:${toString instance.api.port}";
    };
  resolved = lib.mapAttrs resolve enabled;
  values = builtins.attrValues resolved;
in
{
  inherit cfg enabled resolved;
  apiBindings = map (instance: "${instance.vpn.namespace}:${toString instance.api.port}") values;
  peerBindings = map (instance: "${instance.vpn.namespace}:${toString instance.vpn.peerPort}") values;
  secretPrefixes = map (instance: instance.secretPrefix) values;
  stateDirs = map (instance: instance.stateDir) values;
  storageRoots = map (instance: instance.rootDir) values;
}
