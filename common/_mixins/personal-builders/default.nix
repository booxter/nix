{
  lib,
  config,
  hostInventory,
  pkgs,
  username,
  hostname,
  ...
}:
let
  builderSpec = n: hostInventory.nixosHostSpecsByName."builder${toString n}";
  builderSpecs = map builderSpec (lib.range 1 3);
  toBuilderName = hostInventory.toNixosShortDnsName;
in
{
  programs.ssh = {
    extraConfig =
      let
        identityFile = "${config.users.users.${username}.home}/.ssh/id_ed25519";
        user = "ihrachyshka";
        toHost = hostname: ''
          Host ${hostname}
            Hostname ${hostname}
            IdentityFile ${identityFile}
            IdentitiesOnly yes
            User ${user}
        '';
      in
      lib.concatStringsSep "\n" (
        map toHost (
          [
            "frame"
            "mmini"
            "mair"
          ]
          ++ (map toBuilderName builderSpecs)
        )
      );
  };
  environment.systemPackages = [ pkgs.openssh ];

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
        hostName = toBuilderName hostSpec;
        inherit speedFactor;
        system = "x86_64-linux";
        protocol = "ssh-ng";
        maxJobs = 4;
        supportedFeatures = features ++ lib.optionals (hostSpec.nspawnTestBuilder or false) nspawnFeatures;
      };
    in
    (map (toBuilder builderSpeedFactor) builderSpecs)
    ++ lib.optional (hostname != "frame") (toBuilder 200 hostInventory.nixosHostSpecsByName.frame)
    ++ lib.optional (hostname != "mmini") {
      hostName = "mmini";
      systems = [ "aarch64-darwin" ];
      protocol = "ssh-ng";
      maxJobs = 4;
      speedFactor = 100;
      supportedFeatures = features;
    };

  nix.settings.builders-use-substitutes = true;
  nix.distributedBuilds = true;
}
