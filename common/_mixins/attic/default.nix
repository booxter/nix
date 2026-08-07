{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.attic;
  realmAttic = hostInventory.realms.${config.host.realm}.services.attic or null;
  toml = pkgs.formats.toml { };
  clientConfig = toml.generate "attic-client-config.toml" {
    default-server = cfg.cacheName;
    servers.${cfg.cacheName} = {
      endpoint = cfg.endpoint;
      token-file = config.sops.secrets."attic/token".path;
    };
  };
in
{
  options.host.attic = {
    enable = lib.mkEnableOption "Attic store upload client";

    cacheName = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "Attic cache name used as the default upload target.";
    };

    endpoint = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "Attic server endpoint.";
    };
  };

  config = lib.mkMerge [
    {
      host.attic.enable = lib.mkDefault (realmAttic != null);
      assertions = [
        {
          assertion = !cfg.enable || realmAttic != null;
          message = "realm '${config.host.realm}' does not define an Attic service";
        }
        {
          assertion = !cfg.enable || cfg.cacheName != null;
          message = "host.attic.cacheName must be set when Attic is enabled";
        }
        {
          assertion = !cfg.enable || cfg.endpoint != null;
          message = "host.attic.endpoint must be set when Attic is enabled";
        }
      ];
    }
    (lib.mkIf (realmAttic != null) {
      host.attic = {
        cacheName = lib.mkDefault realmAttic.cacheName;
        endpoint = lib.mkDefault realmAttic.endpoint;
      };
    })
    (lib.mkIf cfg.enable {
      environment.etc."attic/config.toml".source = clientConfig;
      sops.secrets."attic/token" = { };
    })
  ];
}
