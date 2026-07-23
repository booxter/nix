{
  hostInventory,
  lib,
  pkgs,
  username,
  isWork,
  ...
}:
let
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
in
{
  nix =
    let
      nixCaches = hostInventory.site.nixCaches;
    in
    {
      package = lib.mkForce pkgs.nixVersions.latest;
      settings = {
        experimental-features = "nix-command flakes";
        warn-dirty = false;
        sandbox = "relaxed";
        nix-path = [ "nixpkgs=flake:nixpkgs" ];
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
        ];
        extra-trusted-public-keys = [
          (readPublicKey ../../../public-keys/nix-cache/numtide.pub)
          (readPublicKey ../../../public-keys/nix-cache/proxmox-nixos.pub)
        ];
      }
      // lib.optionalAttrs (!isWork) {
        substituters = lib.mkForce [
          nixCaches.nixos.url
          nixCaches.home.defaultUrl
        ];
        trusted-public-keys = lib.mkForce [
          nixCaches.nixos.key
          nixCaches.home.key
        ];
      };
    };
}
