{
  config,
  hostInventory,
  hostSpec,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  GiB = 1024 * 1024 * 1024;
  vmDiskSizeGiB = hostSpec.diskSize or 100;
  # VM disks can be much smaller than physical hosts. Start GC at 20%
  # free and target 40%, capped at the physical-host thresholds.
  minFreeGiB = if config.host.isVM then lib.min 40 (builtins.div vmDiskSizeGiB 5) else 40;
  maxFreeGiB = 2 * minFreeGiB;
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
        min-free = minFreeGiB * GiB;
        max-free = maxFreeGiB * GiB;

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
