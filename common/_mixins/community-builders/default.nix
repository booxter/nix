{
  lib,
  config,
  pkgs,
  username,
  ...
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  darwinBuilder = "darwin-builder";
  linuxAarch64Builder = "remote-linux-builder";
  linuxX86Builder = "remote-linux-x86-builder";
  linuxFeatures = "benchmark,big-parallel,kvm,nixos-test";
in
{
  programs.ssh = {
    knownHosts = {
      "aarch64-build-box.nix-community.org" = {
        publicKey = readPublicKey ../../../public-keys/hosts/nix-community-aarch64-build-box.pub;
      };
      "build-box.nix-community.org" = {
        publicKey = readPublicKey ../../../public-keys/hosts/nix-community-build-box.pub;
      };
      "darwin-build-box.nix-community.org" = {
        publicKey = readPublicKey ../../../public-keys/hosts/nix-community-darwin-build-box.pub;
      };
    };
    extraConfig =
      let
        communityBuilderIdentityFile = "${config.users.users.${username}.home}/.ssh/nix-community-builders";
        user = "booxter";
      in
      ''
        Host ${darwinBuilder}
          Hostname darwin-build-box.nix-community.org
          IdentityFile ${communityBuilderIdentityFile}
          User ${user}

        Host ${linuxAarch64Builder}
          Hostname aarch64-build-box.nix-community.org
          IdentityFile ${communityBuilderIdentityFile}
          User ${user}

        Host ${linuxX86Builder}
          Hostname build-box.nix-community.org
          IdentityFile ${communityBuilderIdentityFile}
          User ${user}
      '';
  };
  environment.systemPackages = [ pkgs.openssh ];
  host.nixpkgsReview.communityBuilders = ''
    ssh://${linuxAarch64Builder} aarch64-linux - 10 20 ${linuxFeatures} - -
    ssh://${linuxX86Builder} x86_64-linux - 5 20 ${linuxFeatures} - -
    ssh://${darwinBuilder} x86_64-darwin,aarch64-darwin - 2 20 big-parallel - -
  '';
}
