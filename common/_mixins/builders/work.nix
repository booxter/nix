{
  config,
  lib,
  ...
}:
let
  username = config.host.username;
  identityFile = "${config.users.users.${username}.home}/.ssh/jgwxhwdl4x-nix-builder";
  sshUser = "ihrachyshka";
  enabled =
    builtins.elem "work" config.host.build.pools
    && config.host.isOperatorSeat
    && !config.host.isBuilder;
in
{
  config = lib.mkIf enabled {
    programs.ssh = {
      extraConfig = ''
        Host nvws.local
          Hostname nvws.local
          IdentityFile ${identityFile}
          IdentitiesOnly yes
          User ${sshUser}
      '';
    };

    nix.buildMachines = [
      {
        hostName = "nvws.local";
        system = "x86_64-linux";
        protocol = "ssh-ng";
        sshKey = identityFile;
        inherit sshUser;
        maxJobs = 4;
        speedFactor = 100;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
          "devnet"
          "uid-range"
        ];
      }
    ];
  };
}
