{
  jobsByDomain,
  launchdLib,
  lib,
  managedHomeManagerUserAgents,
  homeManagerUsername,
}:
let
  assertionsFor =
    {
      jobs,
      optionPath,
      serviceConfigName,
      serviceConfigFor,
    }:
    let
      loggingAssertions = lib.mapAttrsToList (
        name: job:
        let
          serviceConfig = serviceConfigFor job;
          stdout = serviceConfig.StandardOutPath;
          stderr = serviceConfig.StandardErrorPath;
        in
        {
          assertion = stdout != null && stderr != null;
          message = "${optionPath}.${name} must define both StandardOutPath and StandardErrorPath";
        }
      ) jobs;
      pathAssertions = lib.concatMap (
        name:
        let
          serviceConfig = serviceConfigFor jobs.${name};
        in
        map
          (field: {
            assertion = serviceConfig.${field} == null || lib.hasPrefix "/" serviceConfig.${field};
            message = "${optionPath}.${name}.${serviceConfigName}.${field} must be an absolute path";
          })
          [
            "StandardOutPath"
            "StandardErrorPath"
          ]
      ) (builtins.attrNames jobs);
    in
    loggingAssertions ++ pathAssertions;
in
lib.concatLists (
  lib.mapAttrsToList (
    domain: jobs:
    assertionsFor {
      jobs = launchdLib.managedJobs jobs;
      optionPath = launchdLib.optionPaths.${domain};
      serviceConfigName = "serviceConfig";
      serviceConfigFor = job: job.serviceConfig;
    }
  ) jobsByDomain
)
++ assertionsFor {
  jobs = managedHomeManagerUserAgents;
  optionPath = "home-manager.users.${homeManagerUsername}.launchd.agents";
  serviceConfigName = "config";
  serviceConfigFor = job: job.config;
}
