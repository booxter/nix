{
  inventory,
  lib,
}:
let
  serverEntries = lib.mapAttrsToList (hostName: server: {
    name = server.network;
    value = { inherit hostName server; };
  }) inventory.servers;
  servers = builtins.listToAttrs serverEntries;
  topologyFor =
    networkName: candidate:
    let
      server = candidate.server;
      managedPeers = builtins.listToAttrs (
        map
          ({ hostName, client }: {
            name = hostName;
            value = {
              host = hostName;
              inherit (client) address publicKey;
              extraAllowedIPs = client.extraAllowedIPs or [ ];
            };
          })
          (
            lib.mapAttrsToList (hostName: client: { inherit hostName client; }) (
              lib.filterAttrs (_: client: client.network == networkName) inventory.clients
            )
          )
      );
      externalPeers = lib.mapAttrs (_: peer: {
        host = null;
        inherit (peer) address publicKey;
        extraAllowedIPs = peer.extraAllowedIPs or [ ];
      }) server.externalPeers;
      duplicatePeerNames = lib.intersectLists (builtins.attrNames managedPeers) (
        builtins.attrNames externalPeers
      );
    in
    {
      inherit duplicatePeerNames;
      cidr = server.cidr;
      clientPolicy = server.clientPolicy // {
        persistentKeepalive = server.clientPolicy.persistentKeepalive or 25;
      };
      peers = externalPeers // managedPeers;
      server = {
        host = candidate.hostName;
        inherit (server)
          address
          listenPort
          publicEndpoint
          publicKey
          ;
      };
    };
  networksWithMetadata = lib.mapAttrs topologyFor servers;
  networks = lib.mapAttrs (
    _: network: removeAttrs network [ "duplicatePeerNames" ]
  ) networksWithMetadata;
in
networks
