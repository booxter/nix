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

  options.host.attic.realmServers = lib.mkOption {
    type = lib.types.attrsOf realmServerType;
    default = model.realmServers;
    readOnly = true;
    internal = true;
    description = "Attic servers discovered in this host's realm.";
  };

  config = {
    environment.systemPackages = lib.optional (config.host.attic.realmServers != { }) pkgs.attic-client;

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
