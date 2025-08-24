{
  lib,
  pkgs,
  username,
  ...
}:
let
  toBuilderName = n: "prox-builder${toString n}vm";
in
{
  programs.ssh = {
    knownHosts = {
      "mmini" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII8s28KbVXwhV4K5c5WDd6adK5wSSjyT7EWLqkF1VhQf";
      };
      "mair" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICHqTUyXOeL1O4JPIDxf8EzUzgKLmkW4C2g9EezZMivL";
      };
      "prox-builder1vm" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIe+cVdgGEOmj1UEN0knbfIqamE026a4s2DCynQ73pvf";
      };
      "prox-builder2vm" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIABPgwULuju7C4KgCD1WLNJo/81FnBCdryVyWkzFzly7";
      };
      "prox-builder3vm" = {
        publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILgwtY+6kcer7n6M0kwQF8wMoYKD6jCYYH2MmpqmaTLc";
      };
    };
    extraConfig =
      let
        identityFile = "/Users/${username}/.ssh/id_ed25519";
        user = "ihrachyshka";
        toHost = hostname: ''
          Host ${hostname}
            Hostname ${hostname}
            IdentityFile ${identityFile}
            User ${user}
        '';
      in
      lib.concatStringsSep "\n" (
        map toHost (
          [
            "mmini"
            "mair"
          ]
          ++ (map toBuilderName (lib.range 1 3))
        )
      );
  };
  environment.systemPackages = [ pkgs.openssh_gssapi ];

  nix.buildMachines =
    let
      toBuilder = n: {
        hostName = toBuilderName n;
        system = "x86_64-linux";
        protocol = "ssh-ng";
        maxJobs = 4;
        speedFactor = 100; # prefer these builders; higher the better
        supportedFeatures = [
          "nixos-test"
          "benchmark"
          "big-parallel"
          "kvm"
        ];
      };
    in
    (map toBuilder (lib.range 1 3));

  nix.settings.builders-use-substitutes = true;
  nix.distributedBuilds = true;
}
