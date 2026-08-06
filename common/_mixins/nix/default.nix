{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.nixCache;
  realmNixCache = hostInventory.realms.${config.host.realm}.services.nixCache or null;
  username = config.host.username;
  readPublicKey = path: lib.removeSuffix "\n" (builtins.readFile path);
  GiB = 1024 * 1024 * 1024;
  hasBuildMachines = config.nix.buildMachines != [ ];
  # Desktops may be used for Proxmox development.
  needsProxmoxCache =
    (config.host.isLinux && config.host.isProxmox) || config.host.isBuilder || config.host.isDesktop;
in
{
  options.host.nixCache = {
    enable = lib.mkEnableOption "realm-provided Nix binary caches";

    substituters = lib.mkOption {
      type = with lib.types; listOf str;
      default = if realmNixCache == null then [ ] else realmNixCache.substituters;
      description = "Nix substituters provided by this host's realm.";
    };

    trustedPublicKeys = lib.mkOption {
      type = with lib.types; listOf str;
      default = if realmNixCache == null then [ ] else realmNixCache.trustedPublicKeys;
      description = "Trusted Nix cache signing keys provided by this host's realm.";
    };
  };

  config = {
    host.nixCache.enable = lib.mkDefault (realmNixCache != null);

    assertions = [
      {
        assertion = !cfg.enable || realmNixCache != null;
        message = "realm '${config.host.realm}' does not define Nix binary caches";
      }
    ];

    nix = {
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
      // lib.optionalAttrs cfg.enable {
        substituters = lib.mkForce cfg.substituters;
        trusted-public-keys = lib.mkForce cfg.trustedPublicKeys;
      };
    };
  };
}
