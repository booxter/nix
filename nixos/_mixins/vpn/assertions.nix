{
  lib,
  vpnModel,
  ...
}:
let
  model = vpnModel;
in
{
  assertions = lib.optionals model.active [
    {
      assertion = model.unknownNamespaces == { };
      message = "host.vpn.clients reference unknown namespaces: ${lib.concatStringsSep ", " (builtins.attrNames model.unknownNamespaces)}";
    }
    {
      assertion = builtins.length model.serviceNames == builtins.length (lib.unique model.serviceNames);
      message = "host.vpn.clients must use unique systemd service names";
    }
  ];
}
