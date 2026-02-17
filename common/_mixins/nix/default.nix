{
  lib,
  pkgs,
  outputs,
  username,
  isWork,
  ...
}:
{
  nix =
    let
      cacheUrl = "http://prox-cachevm:8080/default/";
      cacheKey = "default:+epFjzN1YKGqqeraQczdEfRyIuzgWd6/nrifa0467QQ=";
    in
    {
      package = lib.mkForce pkgs.nixVersions.latest;
      settings = {
        experimental-features = "nix-command flakes";
        trusted-users = [
          "@admin"
          username
        ];
        fallback = true;
        connect-timeout = 2;
        download-attempts = 1;
        max-jobs = 5;

        # Numtide cache for llm-agents.nix
        extra-substituters = [
          "https://cache.numtide.com"
          "https://nixos-raspberrypi.cachix.org"
          "https://cache.saumon.network/proxmox-nixos"
        ];
        extra-trusted-public-keys = [
          "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
          "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
          "proxmox-nixos:D9RYSWpQQC/msZUWphOY2I5RLH5Dd6yQcaHIuug7dWM="
        ];
      }
      // lib.optionalAttrs (!isWork) {
        # attic
        substituters = [
          "https://cache.nixos.org/"
          cacheUrl
        ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          cacheKey
        ];
      };
    };

  nixpkgs = {
    overlays = [
      outputs.overlays.additions
      outputs.overlays.modifications
    ];
    config = {
      allowUnfree = true;
    };
  };
}
