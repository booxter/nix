{
  fleetInventory,
  lib,
}:
let
  inherit (fleetInventory) hosts wireguard;
  ip = import ../../../common/_lib/ipv4.nix { inherit lib; };
  networks = import ../../../common/_mixins/wireguard/model.nix {
    inventory = wireguard;
    inherit lib;
  };
  serverNames = map (server: server.network) (builtins.attrValues wireguard.servers);
  duplicateServerNames = builtins.filter (
    name: builtins.length (builtins.filter (candidate: candidate == name) serverNames) > 1
  ) (lib.unique serverNames);
  unknownServerHosts = builtins.filter (name: !builtins.hasAttr name hosts) (
    builtins.attrNames wireguard.servers
  );
  unknownClientHosts = builtins.filter (name: !builtins.hasAttr name hosts) (
    builtins.attrNames wireguard.clients
  );
  unknownClientNetworks = lib.mapAttrsToList (name: _: name) (
    lib.filterAttrs (_: client: !builtins.hasAttr client.network networks) wireguard.clients
  );
  duplicatePeerNames = lib.unique (
    builtins.concatMap (
      networkName:
      lib.intersectLists
        (builtins.attrNames wireguard.servers.${networks.${networkName}.server.host}.externalPeers)
        (
          lib.mapAttrsToList (name: _: name) (
            lib.filterAttrs (_: client: client.network == networkName) wireguard.clients
          )
        )
    ) (builtins.attrNames networks)
  );
  hasDuplicateNodeField =
    field: network:
    let
      values = [
        network.server.${field}
      ]
      ++ map (peer: peer.${field}) (builtins.attrValues network.peers);
    in
    builtins.length values != builtins.length (lib.unique values);
  duplicateAddressNetworks = builtins.attrNames (
    lib.filterAttrs (_: hasDuplicateNodeField "address") networks
  );
  duplicatePublicKeyNetworks = builtins.attrNames (
    lib.filterAttrs (_: hasDuplicateNodeField "publicKey") networks
  );
  peerAddressesOutsideCidrNetworks = builtins.attrNames (
    lib.filterAttrs (
      _: network:
      builtins.any (peer: !ip.inCidr network.cidr peer.address) (builtins.attrValues network.peers)
    ) networks
  );
  serverAddressesOutsideCidrNetworks = builtins.attrNames (
    lib.filterAttrs (_: network: !ip.inCidr network.cidr network.server.address) networks
  );
  errors =
    lib.optional (duplicateServerNames != [ ]) (
      "WireGuard networks have multiple servers: " + lib.concatStringsSep ", " duplicateServerNames
    )
    ++ lib.optional (unknownServerHosts != [ ]) (
      "WireGuard servers reference unknown hosts: " + lib.concatStringsSep ", " unknownServerHosts
    )
    ++ lib.optional (unknownClientHosts != [ ]) (
      "WireGuard clients reference unknown hosts: " + lib.concatStringsSep ", " unknownClientHosts
    )
    ++ lib.optional (unknownClientNetworks != [ ]) (
      "WireGuard clients reference unknown networks: " + lib.concatStringsSep ", " unknownClientNetworks
    )
    ++ lib.optional (duplicatePeerNames != [ ]) (
      "WireGuard managed and external peer names collide: " + lib.concatStringsSep ", " duplicatePeerNames
    )
    ++ lib.optional (duplicateAddressNetworks != [ ]) (
      "WireGuard nodes have duplicate addresses in networks: "
      + lib.concatStringsSep ", " duplicateAddressNetworks
    )
    ++ lib.optional (duplicatePublicKeyNetworks != [ ]) (
      "WireGuard nodes have duplicate public keys in networks: "
      + lib.concatStringsSep ", " duplicatePublicKeyNetworks
    )
    ++ lib.optional (serverAddressesOutsideCidrNetworks != [ ]) (
      "WireGuard server addresses fall outside network CIDRs: "
      + lib.concatStringsSep ", " serverAddressesOutsideCidrNetworks
    )
    ++ lib.optional (peerAddressesOutsideCidrNetworks != [ ]) (
      "WireGuard peer addresses fall outside network CIDRs: "
      + lib.concatStringsSep ", " peerAddressesOutsideCidrNetworks
    );
in
errors
