{ config, lib }:
let
  launchdLib = import ./lib.nix { inherit lib; };
  username = config.host.username;
  normalizeJob =
    {
      domain,
      enabled,
      managed,
      serviceConfig,
    }:
    {
      inherit
        domain
        enabled
        managed
        serviceConfig
        ;
      label = serviceConfig.Label;
      launchdEnabled = serviceConfig.Disabled != true;
      mode = launchdLib.inferMode serviceConfig;
    };
  normalizeNixDarwinJobs =
    domain: jobs:
    lib.mapAttrs (
      _name: job:
      let
        inherit (job) serviceConfig;
        enabled = serviceConfig.Disabled != true;
      in
      normalizeJob {
        domain = if domain == "daemons" then "system" else "user";
        inherit enabled serviceConfig;
        managed = enabled && launchdLib.hasProgram job;
      }
    ) jobs;
  normalizeHomeManagerJobs = lib.mapAttrs (
    _name: job:
    let
      enabled = job.enable;
      serviceConfig = job.config;
    in
    normalizeJob {
      domain = "user";
      inherit enabled serviceConfig;
      managed = enabled && launchdLib.hasProgramConfig serviceConfig;
    }
  ) config.home-manager.users.${username}.launchd.agents;
  systemJobsByDomain = {
    daemons = normalizeNixDarwinJobs "daemons" config.launchd.daemons;
    agents = normalizeNixDarwinJobs "agents" config.launchd.agents;
  };
in
{
  inherit systemJobsByDomain;
  homeManagerJobs = normalizeHomeManagerJobs;
  homeManagerLaunchdEnabled = config.home-manager.users.${username}.launchd.enable;
}
