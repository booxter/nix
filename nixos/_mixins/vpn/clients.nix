{
  lib,
  vpnModel,
  ...
}:
let
  model = vpnModel;
  services = lib.mapAttrs' (
    name: client:
    let
      namespaceUnit = "${client.namespace}.service";
    in
    lib.nameValuePair name {
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
  systemd.services = services;
}
