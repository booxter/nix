{
  config,
  facts,
  lib,
  ...
}:
let
  builders = config.host.nix.builder-pool;
  username = config.host.username;
  identityFileName = facts.realms.${config.host.realm}.build.sshIdentityFile;
  identityFile = "${config.users.users.${username}.home}/.ssh/${identityFileName}";
  toSshConfig = builder: ''
    Host ${builder.hostName}
      Hostname ${builder.hostName}
      IdentityFile ${identityFile}
      IdentitiesOnly yes
      User ${username}
  '';
  toBuildMachine = builder: {
    inherit (builder)
      hostName
      maxJobs
      speedFactor
      supportedFeatures
      systems
      ;
    protocol = "ssh-ng";
    sshKey = identityFile;
    sshUser = username;
  };
  enabled = config.host.isOperatorSeat && builders != [ ];
in
{
  config = lib.mkIf enabled {
    programs.ssh.extraConfig = lib.concatStringsSep "\n" (map toSshConfig builders);
    nix.buildMachines = map toBuildMachine builders;
  };
}
