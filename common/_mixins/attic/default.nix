{
  config,
  fleetInventory,
  lib,
  pkgs,
  system,
  ...
}:
let
  isLinux = lib.hasSuffix "-linux" system;
  localServer = fleetInventory.atticServers.${config.networking.hostName} or null;
  model = import ./model.nix {
    inherit
      config
      fleetInventory
      lib
      ;
  };
  realmServerType = lib.types.submodule {
    options = {
      hostName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Host providing this realm Attic server.";
      };
      endpoint = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "HTTPS endpoint of this realm Attic server.";
      };
      cacheName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Attic cache hosted by this server.";
      };
      trustedPublicKey = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Nix signing public key for this Attic cache.";
      };
    };
  };
in
{
  imports = [
    ./assertions.nix
    ./config.nix
  ]
  ++ lib.optionals isLinux [
    ./nixos-client.nix
    ./nixos-cache-provisioning.nix
    ./nixos-server.nix
  ];

  options.host.attic = {
    server = {
      enable =
        if isLinux then
          lib.mkOption {
            type = lib.types.bool;
            default = localServer != null;
            internal = true;
            description = "Whether to run an Attic binary cache server.";
          }
        else
          lib.mkOption {
            type = lib.types.bool;
            default = false;
            readOnly = true;
            internal = true;
            description = "Whether to run an Attic binary cache server.";
          };

      endpoint = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = if isLinux && localServer != null then localServer.endpoint else null;
        readOnly = true;
        internal = true;
        description = "Resolved HTTPS endpoint published to clients in this realm.";
      };

      cacheName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = if localServer == null then "default" else localServer.cacheName;
        readOnly = true;
        internal = true;
        description = "Attic cache registered for this server.";
      };

      trustedPublicKey = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = if localServer == null then null else localServer.trustedPublicKey;
        readOnly = true;
        internal = true;
        description = "Nix signing public key registered for this server.";
      };

      environmentFile = lib.mkOption {
        type = lib.types.str;
        default = "/etc/atticd.env";
        description = "Environment file containing the Attic server token secret.";
      };

      storagePath = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "/var/lib/atticd/storage";
        description = "Filesystem path used for Attic server storage.";
      };

      databaseUrl = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Attic database URL, or null to use the upstream SQLite default.";
      };

      localAliases = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        default = [ "nix-cache" ];
        description = "Local DNS aliases published for the Attic HTTPS endpoint.";
      };

      caches = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              public = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = "Whether anonymous clients may pull from this cache.";
              };
              priority = lib.mkOption {
                type = lib.types.int;
                default = 41;
                description = "Nix substituter priority advertised by this cache.";
              };
              retentionPeriod = lib.mkOption {
                type = with lib.types; nullOr nonEmptyStr;
                default = null;
                description = "Cache-specific retention period, or null to use the server default.";
              };
              storeDir = lib.mkOption {
                type = lib.types.nonEmptyStr;
                default = "/nix/store";
                description = "Nix store directory served by this cache.";
              };
              upstreamCacheKeyNames = lib.mkOption {
                type = with lib.types; nonEmptyListOf nonEmptyStr;
                default = [ "cache.nixos.org-1" ];
                description = "Signing key names whose paths clients should avoid uploading.";
              };
            };
          }
        );
        default = { };
        description = "Attic caches created and reconciled by systemd.";
      };

      chunking = {
        narSizeThreshold = lib.mkOption {
          type = lib.types.ints.positive;
          default = 64 * 1024;
        };
        minSize = lib.mkOption {
          type = lib.types.ints.positive;
          default = 16 * 1024;
        };
        avgSize = lib.mkOption {
          type = lib.types.ints.positive;
          default = 64 * 1024;
        };
        maxSize = lib.mkOption {
          type = lib.types.ints.positive;
          default = 256 * 1024;
        };
      };
    };

    realmServers = lib.mkOption {
      type = lib.types.attrsOf realmServerType;
      default = model.realmServers;
      readOnly = true;
      internal = true;
      description = "Attic servers discovered in this host's realm.";
    };
  };

  config = {
    environment.systemPackages = lib.optional (
      config.host.attic.realmServers != { } || config.host.attic.server.enable
    ) pkgs.attic-client;

    host.nix.caches = lib.mapAttrs (_: server: {
      substituter = "${server.endpoint}/${server.cacheName}";
      trustedPublicKeys = [ server.trustedPublicKey ];
      requiredNetwork = config.host.realm;
      priorities = {
        default = 30;
        lan = 10;
        wan = 30;
      };
    }) config.host.attic.realmServers;
  };
}
