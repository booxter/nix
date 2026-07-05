{
  lib,
  config,
  pkgs,
  username,
  ...
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
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
        Host darwin-builder
          Hostname darwin-build-box.nix-community.org
          IdentityFile ${communityBuilderIdentityFile}
          User ${user}

        Host remote-linux-builder
          Hostname aarch64-build-box.nix-community.org
          IdentityFile ${communityBuilderIdentityFile}
          User ${user}

        Host remote-linux-x86-builder
          Hostname build-box.nix-community.org
          IdentityFile ${communityBuilderIdentityFile}
          User ${user}
      '';
  };
  environment.systemPackages = [ pkgs.openssh_gssapi ];
}
