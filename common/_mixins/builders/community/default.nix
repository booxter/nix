{
  config,
  lib,
  ...
}:
let
  readPublicKey = import ../../../_lib/read-public-key.nix { inherit lib; };
  username = config.host.username;
  identityFile = "${config.users.users.${username}.home}/.ssh/nix-community-builders";
  linuxFeatures = [
    "benchmark"
    "big-parallel"
    "kvm"
    "nixos-test"
  ];
  enabled = config.host.realm == "home" && config.host.nix.builderClient != null;
in
{
  config = lib.mkIf enabled {
    host.nix.external-builders = {
      darwin-builder = {
        uses = [ "nixpkgs" ];
        hostName = "darwin-build-box.nix-community.org";
        publicKey = readPublicKey ./keys/darwin.pub;
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
        publicKey = readPublicKey ./keys/linux-arm.pub;
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
        publicKey = readPublicKey ./keys/linux-x86.pub;
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
