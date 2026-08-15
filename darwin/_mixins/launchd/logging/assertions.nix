{
  jobsByDomain,
  launchdLib,
  lib,
}:
let
  assertionsFor =
    domain: jobs:
    let
      optionPath = launchdLib.optionPaths.${domain};
      managedJobs = launchdLib.managedJobs jobs;
      loggingAssertions = lib.mapAttrsToList (
        name: job:
        let
          stdout = job.serviceConfig.StandardOutPath;
          stderr = job.serviceConfig.StandardErrorPath;
        in
        {
          assertion = stdout != null && stderr != null;
          message = "${optionPath}.${name} must define both StandardOutPath and StandardErrorPath";
        }
      ) managedJobs;
      pathAssertions = lib.concatMap (
        name:
        let
          job = managedJobs.${name};
        in
        map
          (field: {
            assertion = job.serviceConfig.${field} == null || lib.hasPrefix "/" job.serviceConfig.${field};
            message = "${optionPath}.${name}.serviceConfig.${field} must be an absolute path";
          })
          [
            "StandardOutPath"
            "StandardErrorPath"
          ]
      ) (builtins.attrNames managedJobs);
    in
    loggingAssertions ++ pathAssertions;
in
lib.concatLists (lib.mapAttrsToList assertionsFor jobsByDomain)
