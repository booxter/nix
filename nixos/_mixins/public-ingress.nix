{
  config,
  hostInventory,
  lib,
  ...
}:
let
  realmPublicIngress = hostInventory.realms.${config.host.realm}.services.publicIngress or null;
in
{
  options.host.publicIngress.enable = lib.mkOption {
    type = lib.types.bool;
    default = realmPublicIngress != null && realmPublicIngress.host == config.networking.hostName;
    readOnly = true;
    internal = true;
    description = "Whether this host provides public HTTPS ingress for its realm.";
  };
}
