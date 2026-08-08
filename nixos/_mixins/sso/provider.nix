{
  config,
  hostInventory,
  lib,
  ...
}:
let
  realmSso = hostInventory.realms.${config.host.realm}.services.sso or null;
  providerHost = if realmSso == null then null else realmSso.providerHost;
in
{
  options.host.sso.provider = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = providerHost != null && providerHost == config.networking.hostName;
      readOnly = true;
      internal = true;
      description = "Whether this host provides SSO for its realm.";
    };

    host = lib.mkOption {
      type = with lib.types; nullOr str;
      default = providerHost;
      readOnly = true;
      internal = true;
      description = "Host that provides SSO for this realm.";
    };
  };
}
