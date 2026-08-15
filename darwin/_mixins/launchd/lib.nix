{ lib }:
let
  hasProgram =
    job:
    job.command != ""
    || job.serviceConfig.Program != null
    || job.serviceConfig.ProgramArguments != null;
  enabledJobs = lib.filterAttrs (_: job: job.serviceConfig.Disabled != true);
in
{
  inherit enabledJobs hasProgram;

  managedJobs = jobs: lib.filterAttrs (_: hasProgram) (enabledJobs jobs);

  optionPaths = {
    daemons = "launchd.daemons";
    agents = "launchd.agents";
    userAgents = "launchd.user.agents";
  };
}
