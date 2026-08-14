{ config, ... }:
let
  cfg = config.host.aurral;
  slskd = if cfg == null then null else cfg.slskd;
  claim = if slskd == null then null else config.host.storage.claims.${slskd.storage.claim} or null;
  namespace =
    if slskd == null then null else config.host.vpn.namespaces.${slskd.vpn.namespace} or null;
  rootDir = if claim == null then null else "${claim.mountPoint}/${slskd.storage.relativePath}";
in
{
  inherit cfg;
  resolved =
    if slskd == null then
      null
    else
      slskd
      // {
        inherit claim namespace rootDir;
        user = "slskd";
        group = "media";
        unitName = "slskd";
        vpnClientName = "slskd";
        incompleteDir = if rootDir == null then null else "${rootDir}/incomplete";
        completedDir = if rootDir == null then null else "${rootDir}/complete";
        apiUrl =
          if namespace == null then
            null
          else
            "http://${namespace.namespaceAddress}:${toString slskd.api.port}";
      };
}
