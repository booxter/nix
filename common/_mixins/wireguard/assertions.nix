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
  requiredServerValues = [
    server.address
    server.cidr
    server.listenPort
    server.publicEndpoint
    server.publicKey
  ];
  validPeer = peer: peer.address != null && peer.publicKey != null;
in
{
  assertions = [
    {
      assertion = !server.enable || lib.all (value: value != null) requiredServerValues;
      message = "Enabled WireGuard servers must declare their address, CIDR, port, endpoint, and public key.";
    }
    {
      assertion =
        !server.enable || (server.clientPolicy.allowedIPs != [ ] && server.clientPolicy.dns != [ ]);
      message = "Enabled WireGuard servers must declare managed-client routes and DNS policy.";
    }
    {
      assertion =
        !server.dynamicDns.enable
        || (server.dynamicDns.hostname != null && server.dynamicDns.username != null);
      message = "Enabled WireGuard dynamic DNS requires a hostname and username.";
    }
    {
      assertion = lib.all validPeer (builtins.attrValues server.externalPeers);
      message = "External WireGuard peers must declare an address and public key.";
    }
    {
      assertion =
        !client.enable
        || (client.address != null && client.publicKey != null && client.privateKeySecret != null);
      message = "Enabled WireGuard clients must declare their address, public key, and private-key secret.";
    }
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
