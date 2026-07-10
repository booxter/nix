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
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  builderSpec = n: hostInventory.nixosHostSpecsByName."builder${toString n}";
  toBuilderName = n: hostInventory.toNixosShortDnsName (builderSpec n);
in
{
  programs.ssh = {
    knownHosts = {
      "frame" = {
        publicKey = readPublicKey ../../../public-keys/hosts/frame.pub;
      };
      "mmini" = {
        publicKey = readPublicKey ../../../public-keys/hosts/mmini.pub;
      };
      "mair" = {
        publicKey = readPublicKey ../../../public-keys/hosts/mair.pub;
      };
      ${toBuilderName 1} = {
        publicKey = readPublicKey ../../../public-keys/hosts/builder1.pub;
      };
      ${toBuilderName 2} = {
        publicKey = readPublicKey ../../../public-keys/hosts/builder2.pub;
      };
      ${toBuilderName 3} = {
        publicKey = readPublicKey ../../../public-keys/hosts/builder3.pub;
      };
    };
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
          ++ (map toBuilderName (lib.range 1 3))
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
      builderSpeedFactor = 100; # prefer these builders; higher the better
      toBuilder = speedFactor: hostName: {
        inherit hostName speedFactor;
        system = "x86_64-linux";
        protocol = "ssh-ng";
        maxJobs = 4;
        supportedFeatures = features;
      };
    in
    (map (toBuilder builderSpeedFactor) (map toBuilderName (lib.range 1 3)))
    ++ lib.optional (hostname != "frame") (toBuilder 200 "frame")
    ++ lib.optional (hostname != "mmini") {
      hostName = "mmini";
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      protocol = "ssh-ng";
      maxJobs = 4;
      speedFactor = 100;
      supportedFeatures = features;
    };

  nix.settings.builders-use-substitutes = true;
  nix.distributedBuilds = true;
}
