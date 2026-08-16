{ lib }:
let
  hasProgramConfig =
    serviceConfig: serviceConfig.Program != null || serviceConfig.ProgramArguments != null;
  hasProgram = job: job.command != "" || hasProgramConfig job.serviceConfig;
  enabledJobs = lib.filterAttrs (_: job: job.serviceConfig.Disabled != true);
in
{
  inherit enabledJobs hasProgram hasProgramConfig;

  managedJobs = jobs: lib.filterAttrs (_: hasProgram) (enabledJobs jobs);

  inferMode =
    serviceConfig:
    if serviceConfig.KeepAlive == true then
      "continuous"
    else if serviceConfig.StartInterval != null || serviceConfig.StartCalendarInterval != null then
      "scheduled"
    else if serviceConfig.RunAtLoad == true then
      "oneshot"
    else
      "on-demand";

  optionPaths = {
    daemons = "launchd.daemons";
    agents = "launchd.agents";
    userAgents = "launchd.user.agents";
  };
}
