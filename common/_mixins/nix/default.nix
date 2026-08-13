{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  GiB = 1024 * 1024 * 1024;
  hasBuildMachines = config.nix.buildMachines != [ ];
in
{
  imports = [
    ./cache
    ./flakehub-cache
  ];

  config = {
    nix = {
      gc = {
        automatic = true;
        options = "--delete-older-than 1d";
      };
      distributedBuilds = hasBuildMachines;
      optimise.automatic = true;
      package = lib.mkForce pkgs.nixVersions.latest;
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

      }
      // lib.optionalAttrs hasBuildMachines {
        builders-use-substitutes = true;
      }
      // lib.optionalAttrs config.nixpkgs.hostPlatform.isDarwin {
        sandbox = "relaxed";
      };
    };
  };
}
