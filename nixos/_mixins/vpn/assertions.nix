{
  lib,
  vpnModel,
  ...
}:
let
  model = vpnModel;
in
{
  assertions = [
    {
      assertion = model.unknownNamespaces == { };
      message = "host.vpn.clients reference unknown namespaces: ${lib.concatStringsSep ", " (builtins.attrNames model.unknownNamespaces)}";
    }
  ];
}
