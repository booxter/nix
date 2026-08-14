{
  config,
  lib,
  outputs,
  ...
}:
let
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
      assertion = model.duplicateServerNames == [ ];
      message = "WireGuard networks must have exactly one server declaration: ${lib.concatStringsSep ", " model.duplicateServerNames}";
    }
    {
      assertion = model.unknownClientNetworks == [ ];
      message = "WireGuard clients reference networks without servers: ${lib.concatStringsSep ", " model.unknownClientNetworks}";
    }
    {
      assertion = model.duplicatePeerNames == [ ];
      message = "Managed and external WireGuard peer names collide: ${lib.concatStringsSep ", " model.duplicatePeerNames}";
    }
    {
      assertion = model.duplicatePeerAddressNetworks == [ ];
      message = "WireGuard peers have duplicate addresses in networks: ${lib.concatStringsSep ", " model.duplicatePeerAddressNetworks}";
    }
    {
      assertion = model.duplicatePeerPublicKeyNetworks == [ ];
      message = "WireGuard peers have duplicate public keys in networks: ${lib.concatStringsSep ", " model.duplicatePeerPublicKeyNetworks}";
    }
    {
      assertion = model.serverAddressesOutsideCidrNetworks == [ ];
      message = "WireGuard server addresses fall outside their network CIDRs: ${lib.concatStringsSep ", " model.serverAddressesOutsideCidrNetworks}";
    }
    {
      assertion = model.peerAddressesOutsideCidrNetworks == [ ];
      message = "WireGuard peer addresses fall outside their network CIDRs: ${lib.concatStringsSep ", " model.peerAddressesOutsideCidrNetworks}";
    }
  ];
}
