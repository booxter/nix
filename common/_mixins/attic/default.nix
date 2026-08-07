{
  config,
  hostInventory,
  lib,
  ...
}:
let
  cfg = config.host.attic;
  realmAttic = hostInventory.realms.${config.host.realm}.services.attic or null;
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
      sops = {
        secrets."attic/token" = { };
        templates."attic-client-config.toml" = {
          owner = "root";
          group = "root";
          mode = "0400";
          content = ''
            default-server = "${cfg.cacheName}"
            [servers.${cfg.cacheName}]
            endpoint = "${cfg.endpoint}"
            token = "${config.sops.placeholder."attic/token"}"
          '';
        };
      };
    })
  ];
}
