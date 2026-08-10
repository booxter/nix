{
  cfg,
  jobs,
  lib,
  monitoredJobs,
}:
[
  {
    assertion = lib.all (name: builtins.hasAttr name jobs) cfg.excludedJobs;
    message = "host.observability.launchd.excludedJobs may only name defined system LaunchDaemons";
  }
  {
    assertion = lib.all (name: builtins.hasAttr name monitoredJobs) (builtins.attrNames cfg.jobModes);
    message = "host.observability.launchd.jobModes may only name monitored system LaunchDaemons";
  }
  {
    assertion = lib.all (name: builtins.hasAttr name monitoredJobs) (builtins.attrNames cfg.jobLabels);
    message = "host.observability.launchd.jobLabels may only name monitored system LaunchDaemons";
  }
  {
    assertion = lib.all (
      labels:
      lib.intersectLists (builtins.attrNames labels) [
        "domain"
        "mode"
        "name"
      ] == [ ]
    ) (builtins.attrValues cfg.jobLabels);
    message = "host.observability.launchd.jobLabels must not override domain, mode, or name";
  }
]
