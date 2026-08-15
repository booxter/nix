{
  jobsByDomain,
  lib,
}:
let
  hasProgram =
    job:
    job.command != ""
    || job.serviceConfig.Program != null
    || job.serviceConfig.ProgramArguments != null;
  isManaged = job: job.serviceConfig.Disabled != true && hasProgram job;
  optionPaths = {
    daemons = "launchd.daemons";
    agents = "launchd.agents";
    userAgents = "launchd.user.agents";
  };
  assertionsFor =
    domain: jobs:
    let
      optionPath = optionPaths.${domain};
      managedJobs = lib.filterAttrs (_: isManaged) jobs;
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
