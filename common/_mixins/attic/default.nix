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
    ./nixos-server.nix
  ];

  options.host.attic = {
    server = {
      enable =
        if isLinux then
          lib.mkOption {
            type = lib.types.bool;
            default = localServer != null;
            readOnly = true;
            internal = true;
            description = "Whether this host is registered as an Attic binary cache server.";
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
        default = if isLinux && config.host.attic.server.enable then localServer.endpoint else null;
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
