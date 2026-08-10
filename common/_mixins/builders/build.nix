{
  config,
  lib,
  ...
}:
let
  builders = lib.filterAttrs (
    _: builder: builtins.elem "build" builder.uses
  ) config.host.nix.builder-pool;
  toBuildMachine = name: builder: {
    inherit (builder)
      maxJobs
      speedFactor
      supportedFeatures
      systems
      ;
    inherit (builder) protocol sshKey sshUser;
    hostName = name;
  };
  enabled = config.host.isOperatorSeat && builders != { };
in
{
  config = lib.mkIf enabled {
    nix.buildMachines = lib.mapAttrsToList toBuildMachine builders;
  };
}
