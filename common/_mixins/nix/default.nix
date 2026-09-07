{
  config,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  GiB = 1024 * 1024 * 1024;
  hasBuildMachines = config.nix.buildMachines != [ ];
  nixPackage =
    inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.nixVersions.latest.appendPatches
      [
        (pkgs.fetchpatch {
          url = "https://github.com/booxter/nix-1/commit/42d741ac8140ab79d75f86e09c51f94497873441.patch";
          hash = "sha256-6zTnacsLMJz4GAK9FnyfIUYjyECBMH7BIKX2Ed/jZXU=";
        })
        (pkgs.fetchpatch {
          url = "https://github.com/booxter/nix-1/commit/99f62a59fbc897e066962848e4036c59c4fc29c1.patch";
          hash = "sha256-T1BWBdwUtLzIK2NhwerSqrJXAJoSviq0iHROC76N9VA=";
        })
        (pkgs.fetchpatch {
          url = "https://github.com/booxter/nix-1/commit/6c23eaef1c437fcf77400ca021d7bd28716ce6d2.patch";
          hash = "sha256-j6vQPYrRPc8hAyP0vbdClnCwvFyv8yChLQl5IE8OmDA=";
        })
        (pkgs.fetchpatch {
          url = "https://github.com/booxter/nix-1/commit/0e40248b4eaf56a766f10ca4900b9b44187c3bfd.patch";
          hash = "sha256-Y//LdfrA3RxGg3M73bEsvtknOChVzMjg5AAuNnTbJkU=";
        })
        (pkgs.fetchpatch {
          url = "https://github.com/booxter/nix-1/commit/7cc467036383c9ee3abe989f5f515b1baee1147d.patch";
          hash = "sha256-WddzR7k4KBpBnG+ajxE3IRVD0enZVcPI8MyCHOCtr/Q=";
        })
      ];
in
{
  imports = [
    ./cache
    ./flakehub
  ];

  nix = {
    gc = {
      automatic = true;
      options = "--delete-older-than 1d";
    };
    distributedBuilds = hasBuildMachines;
    nrBuildUsers = 4;
    optimise.automatic = true;
    package = lib.mkForce nixPackage;
    settings = {
      experimental-features = "nix-command flakes";
      warn-dirty = false;
      nix-path = [ "nixpkgs=flake:nixpkgs" ];
      trusted-users = [
        "@admin"
        username
      ];
      fallback = true;
      connect-timeout = 2;
      download-attempts = 1;
      gc-reserved-space = GiB;
      keep-derivations = false;
      max-jobs = 5;
      min-free = lib.mkDefault (40 * GiB);
      max-free = lib.mkDefault (80 * GiB);
      builders-use-substitutes = hasBuildMachines;
    };
  };
}
