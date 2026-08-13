{ config }:
let
  cfg = config.host.transmission;
  claimMountPoint = config.host.storage.claims.${cfg.storage.claim}.mountPoint;
  vpnNamespace = config.host.vpn.namespaces.${cfg.vpn.namespace} or null;
  baseDir = "${claimMountPoint}/${cfg.storage.relativePath}";
  rpcPort = config.services.transmission.settings.rpc-port;
in
{
  inherit
    baseDir
    cfg
    rpcPort
    vpnNamespace
    ;
  completeDir = baseDir;
  incompleteDir = "${baseDir}/.incomplete";
  watchDir = "${baseDir}/.watch";
  rpcUrl = "http://127.0.0.1:${toString rpcPort}/transmission/rpc";
  stateDir = "${cfg.stateDir}/.config/transmission-daemon";
  minimumCleanerRatio =
    if cfg.torrentCleaner.minimumRatio == null then
      cfg.trackerPolicy.nonPreferred.lowPriorityRatio
    else
      cfg.torrentCleaner.minimumRatio;
}
