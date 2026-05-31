{
  inputs,
  lib,
  pkgs,
  username,
  isWork,
  ...
}:
{
  nix =
    let
      cacheHttpsUrl = "https://nix-cache.home.arpa/default?priority=30";
      cacheKey = "default:+epFjzN1YKGqqeraQczdEfRyIuzgWd6/nrifa0467QQ=";
    in
    {
      package = lib.mkForce pkgs.nixVersions.latest;
      settings = {
        experimental-features = "nix-command flakes";
        warn-dirty = false;
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
          "https://cache.saumon.network/proxmox-nixos"
          "https://virby-nix-darwin.cachix.org"
        ];
        extra-trusted-public-keys = [
          "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
          "proxmox-nixos:D9RYSWpQQC/msZUWphOY2I5RLH5Dd6yQcaHIuug7dWM="
          "virby-nix-darwin.cachix.org-1:z9GiEZeBU5bEeoDQjyfHPMGPBaIQJOOvYOOjGMKIlLo="
        ];
      }
      // lib.optionalAttrs (!isWork) {
        # attic
        substituters = lib.mkForce [
          "https://cache.nixos.org/"
          cacheHttpsUrl
        ];
        trusted-public-keys = lib.mkForce [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          cacheKey
        ];
      };
    };
}
