{ config }:
let
  cfg = config.host.transmission;
  user = "transmission";
  group = "media";
  vpnNamespaceName = "wg";
  lowPriorityRatio = 3.0;
  claimMountPoint =
    if cfg == null then null else config.host.storage.claims.${cfg.storage.claim}.mountPoint;
  vpnNamespace = if cfg == null then null else config.host.vpn.namespaces.${vpnNamespaceName} or null;
  baseDir = if cfg == null then null else "${claimMountPoint}/${cfg.storage.relativePath}";
  rpcPort = config.services.transmission.settings.rpc-port;
in
{
  inherit
    baseDir
    cfg
    group
    rpcPort
    user
    vpnNamespace
    vpnNamespaceName
    ;
  completeDir = baseDir;
  incompleteDir = "${baseDir}/.incomplete";
  watchDir = "${baseDir}/.watch";
  rpcUrl = "http://127.0.0.1:${toString rpcPort}/transmission/rpc";
  stateDir = if cfg == null then null else "${cfg.stateDir}/.config/transmission-daemon";
  trackerPolicy = {
    inherit lowPriorityRatio;
    pauseRatio = 6.0;
    intervalSeconds = 30;
    requestTimeoutSeconds = 20;
  };
  torrentCleaner = {
    minimumAgeDays = 30;
    minimumRatio = lowPriorityRatio;
    maximumAgeDays = 365;
    schedule = "15m";
    delete = true;
  };
}
