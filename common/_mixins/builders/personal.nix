{
  lib,
  config,
  facts,
  ...
}:
let
  username = config.host.username;
  identityFile = "${config.users.users.${username}.home}/.ssh/id_ed25519";
  sshUser = "ihrachyshka";
  builderNames = map (n: "builder${toString n}") (lib.range 1 3);
  builderSpecs = map (name: facts.hosts.nixos.${name}) builderNames;
  sshHosts = [
    "frame"
    "mmini"
    "mair"
  ]
  ++ builderNames;
  features = [
    "nixos-test"
    "benchmark"
    "big-parallel"
    "kvm"
  ];
  nspawnFeatures = [
    "devnet"
    "uid-range"
  ];
  builderSpeedFactor = 100;
  preferredBuilderSpeedFactor = 200;
  toSshConfig = hostname: ''
    Host ${hostname}
      Hostname ${hostname}
      IdentityFile ${identityFile}
      IdentitiesOnly yes
      User ${sshUser}
  '';
  toBuilder = speedFactor: hostSpec: {
    hostName = hostSpec.name;
    inherit speedFactor;
    system = "x86_64-linux";
    protocol = "ssh-ng";
    maxJobs = 4;
    supportedFeatures = features ++ nspawnFeatures;
  };
  enabled = builtins.elem "personal" config.host.build.pools && config.host.isOperatorSeat;
in
{
  config = lib.mkIf enabled {
    programs.ssh.extraConfig = lib.concatStringsSep "\n" (map toSshConfig sshHosts);
    nix.buildMachines =
      (map (toBuilder builderSpeedFactor) builderSpecs)
      ++ lib.optional (config.networking.hostName != "frame") (
        toBuilder preferredBuilderSpeedFactor facts.hosts.nixos.frame
      )
      ++ lib.optional (config.networking.hostName != "mmini") {
        hostName = "mmini";
        systems = [ "aarch64-darwin" ];
        protocol = "ssh-ng";
        maxJobs = 4;
        speedFactor = builderSpeedFactor;
        supportedFeatures = features;
      };
  };
}
