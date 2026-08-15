{
  config,
  lib,
  outputs,
  ...
}:
let
  server = config.host.wireguard.server;
  client = config.host.wireguard.client;
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
in
{
  assertions = [
    {
      assertion = server == null || model.duplicateServerNames == [ ];
      message = "WireGuard networks must have exactly one server declaration: ${lib.concatStringsSep ", " model.duplicateServerNames}";
    }
    {
      assertion = client == null || builtins.hasAttr client.network model.networks;
      message = "WireGuard client references a network without a server: ${
        if client == null then "" else client.network
      }";
    }
    {
      assertion = server == null || model.duplicatePeerNames == [ ];
      message = "Managed and external WireGuard peer names collide: ${lib.concatStringsSep ", " model.duplicatePeerNames}";
    }
    {
      assertion = server == null || model.duplicateAddressNetworks == [ ];
      message = "WireGuard nodes have duplicate addresses in networks: ${lib.concatStringsSep ", " model.duplicateAddressNetworks}";
    }
    {
      assertion = server == null || model.duplicatePublicKeyNetworks == [ ];
      message = "WireGuard nodes have duplicate public keys in networks: ${lib.concatStringsSep ", " model.duplicatePublicKeyNetworks}";
    }
    {
      assertion = server == null || model.serverAddressesOutsideCidrNetworks == [ ];
      message = "WireGuard server addresses fall outside their network CIDRs: ${lib.concatStringsSep ", " model.serverAddressesOutsideCidrNetworks}";
    }
    {
      assertion = server == null || model.peerAddressesOutsideCidrNetworks == [ ];
      message = "WireGuard peer addresses fall outside their network CIDRs: ${lib.concatStringsSep ", " model.peerAddressesOutsideCidrNetworks}";
    }
  ];
}
