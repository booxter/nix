{
  config,
  hostInventory,
  isBuilder,
  isDesktop,
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
      needsProxmoxCache = config.host.isProxmox || isBuilder || isDesktop; # Desktops may be used for development.
    in
    {
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
        max-jobs = 5;

        extra-substituters = lib.optionals needsProxmoxCache [
          "https://cache.saumon.network/proxmox-nixos"
        ];
        extra-trusted-public-keys = lib.optionals needsProxmoxCache [
          (readPublicKey ../../../public-keys/nix-cache/proxmox-nixos.pub)
        ];
      }
      // lib.optionalAttrs config.host.isDarwin {
        sandbox = "relaxed";
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
