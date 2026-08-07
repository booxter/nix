{
  config,
  hostInventory,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  username = config.host.username;
  sshIdentity = hostInventory.ssh.identityFor hostname hostInventory.ssh.purposes.workBuilderClient;
  identityFile = "${config.host.ssh.userDirectory}/${sshIdentity.fileName}";
  builderSpec = hostInventory.nixosHosts.nvws;
  nspawnFeatures = [
    "devnet"
    "uid-range"
  ];
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
          User ${username}
      '';
    };

    nix.buildMachines = [
      {
        hostName = "nvws.local";
        system = "x86_64-linux";
        protocol = "ssh-ng";
        sshKey = identityFile;
        sshUser = username;
        maxJobs = 4;
        speedFactor = 100;
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ]
        ++ lib.optionals (builderSpec.nspawnTestBuilder or false) nspawnFeatures;
      }
    ];
  };
}
