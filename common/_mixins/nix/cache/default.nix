{
  config,
  hostSpec,
  lib,
  outputs,
  ...
}:
let
  readPublicKey = import ../../../_lib/read-public-key.nix { inherit lib; };
  priorityType = with lib.types; nullOr int;
  priorityOptions = {
    default = lib.mkOption {
      type = priorityType;
      default = null;
      description = "Default Nix substituter priority override.";
    };
    tunnelInactive = lib.mkOption {
      type = priorityType;
      default = null;
      description = "Nix substituter priority while the relevant WireGuard tunnel is inactive.";
    };
    tunnelActive = lib.mkOption {
      type = priorityType;
      default = null;
      description = "Nix substituter priority while the relevant WireGuard tunnel is active.";
    };
  };
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
    priorities = priorityOptions;
    reachability = {
      kind = lib.mkOption {
        type = lib.types.enum [
          "public"
          "internal"
        ];
        default = "public";
        description = "Whether the cache is publicly reachable or requires a private network.";
      };
      network = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Private network required to reach an internal cache.";
      };
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
      hostSpec
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
