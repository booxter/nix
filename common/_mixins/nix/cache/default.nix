{
  config,
  lib,
  outputs,
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
  contributionType = lib.types.submodule {
    options = commonCacheOptions // {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to contribute this cache.";
      };
      scope = lib.mkOption {
        type = lib.types.enum [
          "host"
          "realm"
        ];
        default = "host";
        description = "Hosts allowed to consume this cache contribution.";
      };
    };
  };
  cacheType = lib.types.submodule { options = commonCacheOptions; };
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
  cacheLib = import ./lib.nix { inherit lib; };
  caches = builtins.attrValues config.host.nix.caches;
in
{
  imports = [ ./assertions.nix ];

  options.host.nix = {
    cacheContributions = lib.mkOption {
      type = lib.types.attrsOf contributionType;
      default = { };
      internal = true;
      description = "Host-local contributions to the fleet Nix cache pool.";
    };

    caches = lib.mkOption {
      type = lib.types.attrsOf cacheType;
      default = model.caches;
      readOnly = true;
      description = "Nix caches available to this host.";
    };
  };

  config = {
    host.nix.cacheContributions = {
      nixos = {
        substituter = "https://cache.nixos.org/";
        trustedPublicKeys = [ (readPublicKey ./public-keys/nixos.pub) ];
      };

      proxmox = {
        enable =
          config.host.proxmox.node.enable
          || config.host.nix.builder.enable
          || config.host.userEnvironment.roles.developer.enable;
        substituter = "https://cache.saumon.network/proxmox-nixos";
        trustedPublicKeys = [ (readPublicKey ./public-keys/proxmox-nixos.pub) ];
      };
    };

    nix.settings = {
      substituters = lib.mkForce (map (cacheLib.substituterFor "default") caches);
      trusted-public-keys = lib.mkForce (
        lib.unique (builtins.concatMap (cache: cache.trustedPublicKeys) caches)
      );
    };
  };
}
