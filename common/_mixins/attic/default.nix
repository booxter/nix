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
      defaultCache = lib.mkOption {
        type = lib.types.nonEmptyStr;
        description = "Attic cache receiving builds from hosts in this realm.";
      };
      caches = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              cacheName = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "Attic cache name.";
              };
              endpoint = lib.mkOption {
                type = lib.types.nonEmptyStr;
                description = "HTTPS endpoint exposing this Attic cache.";
              };
              public = lib.mkOption {
                type = lib.types.bool;
                description = "Whether anonymous cache reads are allowed.";
              };
              trustedPublicKey = lib.mkOption {
                type = lib.types.nullOr lib.types.nonEmptyStr;
                description = "Nix signing public key, or null until the cache is bootstrapped.";
              };
            };
          }
        );
        description = "Attic caches hosted by this server.";
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

  options.host.attic.realmServers = lib.mkOption {
    type = lib.types.attrsOf realmServerType;
    default = model.realmServers;
    readOnly = true;
    internal = true;
    description = "Attic servers discovered in this host's realm.";
  };

  config = {
    environment.systemPackages = lib.optional (config.host.attic.realmServers != { }) pkgs.attic-client;

    host.nix.caches = lib.mergeAttrsList (
      lib.mapAttrsToList (
        serverName: server:
        lib.mapAttrs' (
          cacheName: cache:
          lib.nameValuePair
            (if cacheName == server.defaultCache then serverName else "${serverName}-${cacheName}")
            {
              substituter = "${cache.endpoint}/${cacheName}";
              trustedPublicKeys = [ cache.trustedPublicKey ];
              requiredNetwork = config.host.realm;
              priorities = {
                default = 30;
                lan = 10;
                wan = 30;
              };
            }
        ) (lib.filterAttrs (_: cache: cache.trustedPublicKey != null) server.caches)
      ) config.host.attic.realmServers
    );
  };
}
