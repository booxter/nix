{
  cfg,
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
      exclusions = cfg.exclusions.${domain};
      optionPath = optionPaths.${domain};
      managedJobs = lib.filterAttrs (_: isManaged) jobs;
      loggingAssertions = lib.mapAttrsToList (
        name: job:
        let
          stdout = job.serviceConfig.StandardOutPath;
          stderr = job.serviceConfig.StandardErrorPath;
          excluded = builtins.hasAttr name exclusions;
        in
        {
          assertion = excluded || (stdout != null && stderr != null);
          message = "${optionPath}.${name} must define both StandardOutPath and StandardErrorPath or have a documented host.launchd.logging.exclusions.${domain} entry";
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
      exclusionAssertions = lib.mapAttrsToList (name: _: {
        assertion = builtins.hasAttr name managedJobs;
        message = "host.launchd.logging.exclusions.${domain}.${name} must name an enabled launchd job with a program";
      }) exclusions;
    in
    loggingAssertions ++ pathAssertions ++ exclusionAssertions;
in
lib.concatLists (lib.mapAttrsToList assertionsFor jobsByDomain)
