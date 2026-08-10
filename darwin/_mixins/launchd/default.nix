{ config, lib, ... }:
let
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
in
{
  assertions =
    assertionsFor "launchd.daemons" config.launchd.daemons
    ++ assertionsFor "launchd.agents" config.launchd.agents
    ++ assertionsFor "launchd.user.agents" config.launchd.user.agents;
}
