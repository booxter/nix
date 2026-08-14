{
  lib,
  vpnModel,
  ...
}:
let
  model = vpnModel;
  services = lib.mapAttrs' (
    _: client:
    let
      namespaceUnit = "${client.namespace}.service";
    in
    lib.nameValuePair client.serviceName {
      unitConfig = {
        After = [ namespaceUnit ];
        BindsTo = [ namespaceUnit ];
        PartOf = [ namespaceUnit ];
      };
      vpnConfinement = {
        enable = true;
        vpnNamespace = client.namespace;
      };
    }
  ) model.validClients;
in
{
  config = lib.mkIf model.active {
    systemd.services = services;
  };
}
