{
  config,
  facts,
  hostSpec,
  lib,
  outputs,
  ...
}:
let
  priorityType = with lib.types; nullOr int;
  priorityOptions = {
    default = lib.mkOption {
      type = priorityType;
      default = null;
      description = "Default Nix substituter priority override.";
    };
    lan = lib.mkOption {
      type = priorityType;
      default = null;
      description = "Nix substituter priority while directly connected to the LAN.";
    };
    vpn = lib.mkOption {
      type = priorityType;
      default = null;
      description = "Nix substituter priority while connected through VPN.";
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
  substituterFor =
    profile: cache:
    let
      profilePriority = cache.priorities.${profile};
      priority = if profilePriority == null then cache.priorities.default else profilePriority;
    in
    cache.substituter + lib.optionalString (priority != null) "?priority=${toString priority}";
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
        trustedPublicKeys = [ facts.public-keys.nix-cache.nixos ];
      };

      proxmox = {
        enable = config.host.isProxmox || config.host.nix.builder.enable || config.host.isOperatorSeat;
        substituter = "https://cache.saumon.network/proxmox-nixos";
        trustedPublicKeys = [ facts.public-keys.nix-cache.proxmox-nixos ];
      };
    };

    nix.settings = {
      substituters = lib.mkForce (map (substituterFor "default") caches);
      trusted-public-keys = lib.mkForce (
        lib.unique (builtins.concatMap (cache: cache.trustedPublicKeys) caches)
      );
    };
  };
}
