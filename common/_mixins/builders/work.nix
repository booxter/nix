{
  config,
  hostInventory,
  lib,
  ...
}:
let
  username = config.host.username;
  identityFile = "${config.users.users.${username}.home}/.ssh/jgwxhwdl4x-nix-builder";
  user = "ihrachyshka";
  builderSpec = hostInventory.nixosHosts.nvws;
  nspawnFeatures = [
    "devnet"
    "uid-range"
  ];
in
{
  config = lib.mkIf (config.host.isWork && !config.host.isBuilder) {
    programs.ssh = {
      extraConfig = ''
        Host nvws.local
          Hostname nvws.local
          IdentityFile ${identityFile}
          IdentitiesOnly yes
          User ${user}
      '';
    };

    nix.buildMachines = [
      {
        hostName = "nvws.local";
        system = "x86_64-linux";
        protocol = "ssh-ng";
        sshKey = identityFile;
        sshUser = user;
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

    nix.settings.builders-use-substitutes = true;
    nix.distributedBuilds = true;
  };
}
