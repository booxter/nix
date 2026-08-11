{
  config,
  facts,
  lib,
  ...
}:
let
  username = config.host.username;
  identityFile = "${config.users.users.${username}.home}/.ssh/nix-community-builders";
  linuxFeatures = [
    "benchmark"
    "big-parallel"
    "kvm"
    "nixos-test"
  ];
  enabled = config.host.realm == "home" && config.host.isOperatorSeat;
in
{
  config = lib.mkIf enabled {
    host.nix.external-builders = {
      darwin-builder = {
        uses = [ "nixpkgs" ];
        hostName = "darwin-build-box.nix-community.org";
        publicKey = facts.public-keys.hosts.nix-community-darwin-build-box;
        sshKey = identityFile;
        sshUser = "booxter";
        systems = [ "aarch64-darwin" ];
        maxJobs = 2;
        speedFactor = 20;
        supportedFeatures = [ "big-parallel" ];
      };
      remote-linux-builder = {
        uses = [ "nixpkgs" ];
        hostName = "aarch64-build-box.nix-community.org";
        publicKey = facts.public-keys.hosts.nix-community-aarch64-build-box;
        sshKey = identityFile;
        sshUser = "booxter";
        systems = [ "aarch64-linux" ];
        maxJobs = 10;
        speedFactor = 20;
        supportedFeatures = linuxFeatures;
      };
      remote-linux-x86-builder = {
        uses = [ "nixpkgs" ];
        hostName = "build-box.nix-community.org";
        publicKey = facts.public-keys.hosts.nix-community-build-box;
        sshKey = identityFile;
        sshUser = "booxter";
        systems = [ "x86_64-linux" ];
        maxJobs = 5;
        speedFactor = 20;
        supportedFeatures = linuxFeatures;
      };
    };
  };
}
