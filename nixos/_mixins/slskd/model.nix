{ config, ... }:
let
  cfg = config.host.aurral;
  slskd = if cfg == null then null else cfg.slskd;
  claim = if cfg == null then null else config.host.storage.claims.${cfg.storageClaim} or null;
  namespace =
    if slskd == null then null else config.host.vpn.namespaces.${slskd.vpnNamespace} or null;
  rootDir = if claim == null then null else "${claim.mountPoint}/slskd";
in
{
  inherit cfg;
  resolved =
    if slskd == null then
      null
    else
      {
        inherit claim namespace rootDir;
        secretPrefix = "slskd";
        storage.claim = cfg.storageClaim;
        storage.relativePath = "slskd";
        api.port = 5030;
        vpn.namespace = slskd.vpnNamespace;
        vpn.peerPort = slskd.peerPort;
        user = "slskd";
        group = "media";
        unitName = "slskd";
        incompleteDir = if rootDir == null then null else "${rootDir}/incomplete";
        completedDir = if rootDir == null then null else "${rootDir}/complete";
        apiUrl = if namespace == null then null else "http://${namespace.namespaceAddress}:5030";
      };
}
