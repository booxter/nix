{
  config,
  hostSpec,
  lib,
  outputs,
}:
let
  ip = import ../../_lib/ipv4.nix { inherit lib; };
  localHost = hostSpec.name;
  localCandidate = {
    hostName = localHost;
    inherit (config.host.wireguard) client server;
  };
  otherConfigurations = builtins.removeAttrs (
    outputs.nixosConfigurations // outputs.darwinConfigurations
  ) [ localHost ];
  candidates =
    lib.mapAttrs (_: configuration: {
      hostName = configuration.config.networking.hostName;
      inherit (configuration.config.host.wireguard) client server;
    }) otherConfigurations
    // {
      ${localHost} = localCandidate;
    };
  serverEntries = builtins.concatMap (
    candidate:
    lib.optional candidate.server.enable {
      name = candidate.server.network;
      value = candidate;
    }
  ) (builtins.attrValues candidates);
  serverNames = map (entry: entry.name) serverEntries;
  duplicateServerNames = lib.unique (
    builtins.filter (
      name: builtins.length (builtins.filter (candidate: candidate == name) serverNames) > 1
    ) serverNames
  );
  servers = builtins.listToAttrs serverEntries;
  clients = builtins.filter (candidate: candidate.client.enable) (builtins.attrValues candidates);
  unknownClientNetworks = lib.unique (
    map (candidate: candidate.client.network) (
      builtins.filter (candidate: !builtins.hasAttr candidate.client.network servers) clients
    )
  );
  topologyFor =
    networkName: candidate:
    let
      server = candidate.server;
      managedPeers = builtins.listToAttrs (
        map (candidate: {
          name = candidate.hostName;
          value = {
            host = candidate.hostName;
            inherit (candidate.client)
              address
              extraAllowedIPs
              publicKey
              ;
          };
        }) (builtins.filter (candidate: candidate.client.network == networkName) clients)
      );
      externalPeers = lib.mapAttrs (_: peer: peer // { host = null; }) server.externalPeers;
      duplicatePeerNames = lib.intersectLists (builtins.attrNames managedPeers) (
        builtins.attrNames externalPeers
      );
    in
    {
      inherit duplicatePeerNames;
      cidr = server.cidr;
      clientPolicy = server.clientPolicy;
      peers = externalPeers // managedPeers;
      server =
        removeAttrs server [
          "cidr"
          "clientPolicy"
          "enable"
          "externalPeers"
          "network"
        ]
        // {
          host = candidate.hostName;
        };
    };
  networksWithMetadata = lib.mapAttrs topologyFor servers;
  duplicatePeerNames = lib.unique (
    builtins.concatMap (network: network.duplicatePeerNames) (builtins.attrValues networksWithMetadata)
  );
  networks = lib.mapAttrs (
    _: network: removeAttrs network [ "duplicatePeerNames" ]
  ) networksWithMetadata;
  hasDuplicatePeerField =
    field: network:
    let
      values = map (peer: peer.${field}) (builtins.attrValues network.peers);
    in
    builtins.length values != builtins.length (lib.unique values);
  duplicatePeerAddressNetworks = builtins.attrNames (
    lib.filterAttrs (_: hasDuplicatePeerField "address") networks
  );
  duplicatePeerPublicKeyNetworks = builtins.attrNames (
    lib.filterAttrs (_: hasDuplicatePeerField "publicKey") networks
  );
  peerAddressesOutsideCidrNetworks = builtins.attrNames (
    lib.filterAttrs (
      _: network:
      builtins.any (
        peer: peer.address != null && network.cidr != null && !ip.inCidr network.cidr peer.address
      ) (builtins.attrValues network.peers)
    ) networks
  );
  serverAddressesOutsideCidrNetworks = builtins.attrNames (
    lib.filterAttrs (
      _: network:
      network.server.address != null
      && network.cidr != null
      && !ip.inCidr network.cidr network.server.address
    ) networks
  );
in
{
  inherit
    duplicatePeerAddressNetworks
    duplicatePeerNames
    duplicatePeerPublicKeyNetworks
    duplicateServerNames
    networks
    peerAddressesOutsideCidrNetworks
    serverAddressesOutsideCidrNetworks
    unknownClientNetworks
    ;
}
