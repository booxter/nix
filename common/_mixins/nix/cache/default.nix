{
  config,
  lib,
  ...
}:
let
  readPublicKey = import ../../../_lib/read-public-key.nix { inherit lib; };
  commonCacheOptions = {
    substituter = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = "Base Nix substituter URL.";
    };
    trustedPublicKeys = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = [ ];
      description = "Signing keys trusted for this cache.";
    };
    priorities = lib.mkOption {
      type = with lib.types; attrsOf int;
      default = { };
      description = "Substituter priority overrides keyed by network profile.";
    };
    requiredNetwork = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = null;
      description = "Private network required to reach this cache, or null for a public cache.";
    };
  };
  cacheType = lib.types.submodule { options = commonCacheOptions; };
  cacheLib = import ./lib.nix { inherit lib; };
  proxmoxCache = import ./proxmox.nix { inherit lib; };
  caches = builtins.attrValues config.host.nix.caches;
in
{
  options.host.nix.caches = lib.mkOption {
    type = lib.types.attrsOf cacheType;
    default = { };
    description = "Nix caches available to this host.";
  };

  config = {
    host.nix.caches.nixos = {
      substituter = "https://cache.nixos.org/";
      trustedPublicKeys = [ (readPublicKey ./public-keys/nixos.pub) ];
    };

    host.nix.caches.proxmox = lib.mkIf (
      config.host.nix.builder.enable || config.host.nix.builder.client.enable
    ) proxmoxCache;

    nix.settings = {
      substituters = lib.mkForce (map (cacheLib.substituterFor "default") caches);
      trusted-public-keys = lib.mkForce (
        lib.unique (builtins.concatMap (cache: cache.trustedPublicKeys) caches)
      );
    };
  };
}
