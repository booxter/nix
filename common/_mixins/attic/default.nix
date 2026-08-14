{
  config,
  lib,
  outputs,
  pkgs,
  system,
  ...
}:
let
  isDarwin = lib.hasSuffix "-darwin" system;
  isLinux = lib.hasSuffix "-linux" system;
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
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
  ]
  ++ lib.optional isDarwin ./darwin-client.nix;

  options.host.attic = {
    server = {
      enable =
        if isLinux then
          lib.mkEnableOption "an Attic binary cache server"
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
        default =
          if isLinux && config.host.attic.server.enable then
            config.host.web.services.atticd.internal.url
          else
            null;
        readOnly = true;
        internal = true;
        description = "Resolved HTTPS endpoint published to clients in this realm.";
      };

      cacheName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "default";
        description = "Attic cache published by this server.";
      };

      trustedPublicKey = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "Nix signing public key published to clients in this realm.";
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

    host.nix.cacheContributions.${config.networking.hostName} =
      lib.mkIf config.host.attic.server.enable
        {
          scope = "realm";
          substituter = "${config.host.attic.server.endpoint}/${config.host.attic.server.cacheName}";
          trustedPublicKeys = [ config.host.attic.server.trustedPublicKey ];
          requiredNetwork = config.host.realm;
          priorities = {
            default = 30;
            lan = 10;
            wan = 30;
          };
        };
  };
}
