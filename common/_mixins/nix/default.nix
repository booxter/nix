{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  GiB = 1024 * 1024 * 1024;
  hasBuildMachines = config.nix.buildMachines != [ ];
in
{
  nix =
    let
      nixCaches = hostInventory.site.nixCaches;
      # Desktops may be used for Proxmox development.
      needsProxmoxCache =
        (config.host.isLinux && config.host.isProxmox) || config.host.isBuilder || config.host.isDesktop;
    in
    {
      gc = {
        automatic = true;
        options = "--delete-older-than 1d";
      };
      distributedBuilds = hasBuildMachines;
      optimise.automatic = true;
      package = lib.mkForce pkgs.nixVersions.latest;
      settings = {
        builders-use-substitutes = hasBuildMachines;
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
      // lib.optionalAttrs (!config.host.isWork) {
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
