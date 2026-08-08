{
  config,
  hostInventory,
  lib,
  ...
}:
let
  realmPki = hostInventory.realms.${config.host.realm}.services.internalPki or null;
  providerHost = if realmPki == null then null else realmPki.providerHost;
in
{
  options.host.internalPki.provider = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = providerHost != null && providerHost == config.networking.hostName;
      readOnly = true;
      internal = true;
      description = "Whether this host provides the internal PKI for its realm.";
    };

    host = lib.mkOption {
      type = with lib.types; nullOr str;
      default = providerHost;
      readOnly = true;
      internal = true;
      description = "Host that provides the internal PKI for this realm.";
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/step-ca";
      readOnly = true;
      internal = true;
      description = "Persistent state directory for the realm certificate authority.";
    };
  };
}
