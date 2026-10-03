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
              authenticated = lib.mkOption {
                type = lib.types.bool;
                description = "Whether cache reads require an authentication token.";
              };
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
                description = "Whether the cache is advertised outside its host realm.";
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

  options.host.attic.publishCaches = lib.mkOption {
    type = with lib.types; attrsOf (nonEmptyListOf nonEmptyStr);
    default =
      if config.host.nix.builderClient == null then
        { }
      else
        lib.mapAttrs (_: server: [ server.defaultCache ]) model.realmServers;
    description = "Attic caches receiving completed builds, grouped by server name.";
  };

  config = {
    environment.systemPackages = lib.optional (
      config.host.attic.publishCaches != { }
    ) pkgs.attic-client;

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
              requiredNetwork = if cache.public then null else config.host.realm;
              priorities =
                if cache.public then
                  {
                    default = 30;
                    lan = 30;
                    wan = 10;
                  }
                else
                  {
                    default = 30;
                    lan = 10;
                    wan = 30;
                  };
            }
        ) (lib.filterAttrs (_: cache: cache.trustedPublicKey != null) server.caches)
      ) (config.host.attic.realmServers // model.publicServers)
    );
  };
}
