{
  lib,
  config,
  pkgs,
  username,
  ...
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  linuxFeatures = [
    "benchmark"
    "big-parallel"
    "kvm"
    "nixos-test"
  ];
  communityBuilders = {
    darwin-builder = {
      hostName = "darwin-build-box.nix-community.org";
      publicKeyFile = ../../../public-keys/hosts/nix-community-darwin-build-box.pub;
      systems = [ "aarch64-darwin" ];
      maxJobs = 2;
      speedFactor = 20;
      supportedFeatures = [ "big-parallel" ];
    };
    remote-linux-builder = {
      hostName = "aarch64-build-box.nix-community.org";
      publicKeyFile = ../../../public-keys/hosts/nix-community-aarch64-build-box.pub;
      systems = [ "aarch64-linux" ];
      maxJobs = 10;
      speedFactor = 20;
      supportedFeatures = linuxFeatures;
    };
    remote-linux-x86-builder = {
      hostName = "build-box.nix-community.org";
      publicKeyFile = ../../../public-keys/hosts/nix-community-build-box.pub;
      systems = [ "x86_64-linux" ];
      maxJobs = 5;
      speedFactor = 20;
      supportedFeatures = linuxFeatures;
    };
  };
  formatList = values: if values == [ ] then "-" else lib.concatStringsSep "," values;
in
{
  programs.ssh = {
    knownHosts = lib.mapAttrs' (
      _: builder:
      lib.nameValuePair builder.hostName {
        publicKey = readPublicKey builder.publicKeyFile;
      }
    ) communityBuilders;
    extraConfig =
      let
        communityBuilderIdentityFile = "${config.users.users.${username}.home}/.ssh/nix-community-builders";
        user = "booxter";
      in
      lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: builder: ''
          Host ${name}
            Hostname ${builder.hostName}
            IdentityFile ${communityBuilderIdentityFile}
            User ${user}
        '') communityBuilders
      );
  };
  environment.systemPackages = [ pkgs.openssh ];
  host.nixpkgsReview.communityBuilders = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      name: builder:
      "ssh://${name} ${formatList builder.systems} - ${toString builder.maxJobs} "
      + "${toString builder.speedFactor} ${formatList builder.supportedFeatures} - -"
    ) communityBuilders
  );
}
