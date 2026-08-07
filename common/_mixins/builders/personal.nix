{
  lib,
  config,
  hostInventory,
  ...
}:
let
  hostname = config.networking.hostName;
  username = config.host.username;
  sshIdentity = hostInventory.ssh.identityFor hostname hostInventory.ssh.purposes.personalBuilderClient;
  builderSpec = n: hostInventory.nixosHosts."builder${toString n}";
  builderSpecs = map builderSpec (lib.range 1 3);
in
{
  config = lib.mkIf (builtins.elem "personal" config.host.build.pools && config.host.isOperatorSeat) {
    programs.ssh = {
      extraConfig =
        let
          identityFile = "${config.host.ssh.userDirectory}/${sshIdentity.fileName}";
          toHost = hostname: ''
            Host ${hostname}
              Hostname ${hostname}
              IdentityFile ${identityFile}
              IdentitiesOnly yes
              User ${username}
          '';
        in
        lib.concatStringsSep "\n" (
          map toHost (
            [
              "frame"
              "mmini"
              "mair"
            ]
            ++ (map (spec: spec.name) builderSpecs)
          )
        );
    };
    nix.buildMachines =
      let
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
        builderSpeedFactor = 100; # prefer these builders; higher the better
        toBuilder = speedFactor: hostSpec: {
          hostName = hostSpec.name;
          inherit speedFactor;
          system = "x86_64-linux";
          protocol = "ssh-ng";
          maxJobs = 4;
          supportedFeatures = features ++ lib.optionals (hostSpec.nspawnTestBuilder or false) nspawnFeatures;
        };
      in
      (map (toBuilder builderSpeedFactor) builderSpecs)
      ++ lib.optional (config.networking.hostName != "frame") (
        toBuilder 200 hostInventory.nixosHosts.frame
      )
      ++ lib.optional (config.networking.hostName != "mmini") {
        hostName = "mmini";
        systems = [ "aarch64-darwin" ];
        protocol = "ssh-ng";
        maxJobs = 4;
        speedFactor = 100;
        supportedFeatures = features;
      };
  };
}
