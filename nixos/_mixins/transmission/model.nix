{ config }:
let
  cfg = config.host.transmission;
  user = "transmission";
  group = "media";
  vpnNamespaceName = "wg";
  targetRatio = 3.0;
  mkRatioPriority = atOrAboveTarget: {
    inherit targetRatio atOrAboveTarget;
    belowTarget = "high";
  };
  renderClassPolicy = policy: {
    priority = {
      target_ratio = policy.priority.targetRatio;
      below_target = policy.priority.belowTarget;
      at_or_above_target = policy.priority.atOrAboveTarget;
    };
    stop =
      if policy.stop == null then
        null
      else
        {
          minimum_ratio = policy.stop.minimumRatio;
          require_complete = policy.stop.requireComplete;
        };
    cleanup =
      if policy.cleanup == null then
        null
      else
        {
          completed = {
            minimum_ratio = policy.cleanup.completed.minimumRatio;
            minimum_age_days = policy.cleanup.completed.minimumAgeDays;
          };
          maximum_age_days = policy.cleanup.maximumAgeDays;
        };
  };
  torrentPolicy = {
    preferred = {
      priority = mkRatioPriority "high";
      stop = null;
      cleanup = null;
    };
    nonPreferred = {
      priority = mkRatioPriority "low";
      stop = {
        minimumRatio = 6.0;
        requireComplete = true;
      };
      cleanup = {
        completed = {
          minimumRatio = targetRatio;
          minimumAgeDays = 30;
        };
        maximumAgeDays = 365;
      };
    };
    reconcileIntervalSeconds = 30;
    requestTimeoutSeconds = 20;
    cleanupSchedule = "15m";
    deleteOnCleanup = true;
  };
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
    torrentPolicy
    user
    vpnNamespace
    vpnNamespaceName
    ;
  completeDir = baseDir;
  incompleteDir = "${baseDir}/.incomplete";
  watchDir = "${baseDir}/.watch";
  rpcUrl = "http://127.0.0.1:${toString rpcPort}/transmission/rpc";
  stateDir = if cfg == null then null else "${cfg.stateDir}/.config/transmission-daemon";
  torrentPolicyDocument = {
    preferred = renderClassPolicy torrentPolicy.preferred;
    non_preferred = renderClassPolicy torrentPolicy.nonPreferred;
  };
}
