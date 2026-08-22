{ config, lib, ... }:
let
  readPublicKey = import ../../common/_lib/read-public-key.nix { inherit lib; };
in
{
  system.stateVersion = 5;

  host.nix.builder = { };
  host.nix.builderClient = { };

  host.nix.cacheWarmer = {
    builderMaxJobs = {
      builder1 = 1;
      builder2 = 1;
      builder3 = 1;
    };
    fleet.enable = true;
    nixpkgs = {
      enable = true;
      runner = "mmini";
      references = [
        "github:NixOS/nixpkgs/master"
        "github:NixOS/nixpkgs/nixos-unstable"
        "github:NixOS/nixpkgs/staging"
        "github:NixOS/nixpkgs/staging-next"
        "github:NixOS/nixpkgs/staging-26.05"
        "github:NixOS/nixpkgs/release-26.05"
      ];
      systems = [
        "aarch64-darwin"
        "x86_64-linux"
      ];
      excludePnamePatterns = [
        "firefox.*"
        "thunderbird.*"
      ];
    };
  };

  host.network.interfaces.en0 = { };

  host.remote-control = {
    client = {
      vnc = { };
      x11 = { };
    };
    server.vnc = { };
  };

  host.ssh = {
    credentials.backend = "yubikey";
    operator.authorizedKeys = [
      (readPublicKey ../../common/_mixins/ssh/public-keys/mmini.pub)
      (readPublicKey ../../common/_mixins/ssh/public-keys/yubikey.pub)
    ];
    tickets.issuer = {
      publicKey = readPublicKey ../../common/_mixins/ssh/public-keys/yubikey.pub;
      keyName = "id_ed25519_sk_rk";
      useAgent = false;
    };
  };

  host.security = {
    smartCard = { };
    secrets.operator.ageIdentity = {
      backend = "yubikey";
      path = "/Users/${config.host.username}/.config/sops/age/yubi-nix.txt";
    };
  };
}
