{ config, lib, ... }:
let
  launchdLib = import ./lib.nix { inherit lib; };
  storePrefix = "${builtins.storeDir}/";
  usesNixStore = job: lib.hasInfix storePrefix (builtins.toJSON job.serviceConfig);
  usesWait4Path =
    job:
    let
      programArguments = job.serviceConfig.ProgramArguments;
    in
    job.command != ""
    && job.serviceConfig.Program == null
    && programArguments != null
    && builtins.length programArguments >= 3
    && builtins.elemAt programArguments 0 == "/bin/sh"
    && builtins.elemAt programArguments 1 == "-c"
    && lib.hasPrefix "/bin/wait4path ${builtins.storeDir} && exec " (
      builtins.elemAt programArguments 2
    );
  assertionsFor =
    optionPath: jobs:
    lib.mapAttrsToList (name: job: {
      assertion = !usesNixStore job || usesWait4Path job;
      message = "${optionPath}.${name} references the Nix store without waiting for it; use the command option instead of serviceConfig.Program or serviceConfig.ProgramArguments";
    }) jobs;
  managedUserAgentNames = builtins.attrNames (launchdLib.managedJobs config.launchd.user.agents);
in
{
  assertions = [
    {
      # nix-darwin loads changed user agents through the primary user's launchd
      # domain, which aborts remote activation when no GUI session exists.
      # TODO: Report and fix this upstream, then remove this assertion.
      assertion = managedUserAgentNames == [ ];
      message = "launchd.user.agents is unsafe for headless remote activation; use home-manager.users.<name>.launchd.agents instead: ${lib.concatStringsSep ", " managedUserAgentNames}";
    }
  ]
  ++ assertionsFor "launchd.daemons" config.launchd.daemons
  ++ assertionsFor "launchd.agents" config.launchd.agents;
}
