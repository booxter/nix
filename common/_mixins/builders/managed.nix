{
  config,
  hostInventory,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  username = config.host.username;
  poolBuilders = builtins.concatMap (
    pool: hostInventory.builders.byPool.${pool} or [ ]
  ) config.host.build.pools;
  builders = builtins.filter (builder: builder.name != hostname) poolBuilders;
  renderBuilder =
    builder:
    let
      sshIdentity = hostInventory.ssh.identityForBuilderPool hostname builder.pool;
      identityFile = "${config.host.ssh.userDirectory}/${sshIdentity.fileName}";
      hostPatterns = lib.concatStringsSep " " (
        lib.unique [
          builder.name
          builder.sshHost
        ]
      );
    in
    {
      machine = {
        hostName = builder.sshHost;
        inherit (builder)
          maxJobs
          speedFactor
          supportedFeatures
          systems
          ;
        protocol = "ssh-ng";
        sshKey = identityFile;
        sshUser = username;
      };
      sshConfig = ''
        Host ${hostPatterns}
          Hostname ${builder.sshHost}
          IdentityFile ${identityFile}
          IdentitiesOnly yes
          User ${username}
      '';
    };
  renderedBuilders = map renderBuilder builders;
in
{
  config = lib.mkIf (config.host.isOperatorSeat && builders != [ ]) {
    nix.buildMachines = map (builder: builder.machine) renderedBuilders;
    programs.ssh.extraConfig = lib.concatMapStringsSep "\n" (
      builder: builder.sshConfig
    ) renderedBuilders;
  };
}
