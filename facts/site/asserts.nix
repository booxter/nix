{ facts, lib }:
raw:
let
  dnsDomains = map (record: record.domain) raw.lan.dnsRecords;
  knownHosts = builtins.attrNames facts.hosts.hostSpecsByName;
  wireguardNetworks = lib.mapAttrsToList (name: network: network // { inherit name; }) raw.wireguard;
  wireguardPeers = builtins.concatMap (network: builtins.attrValues network.peers) wireguardNetworks;
  registeredPeerHosts = map (peer: peer.host) (builtins.filter (peer: peer ? host) wireguardPeers);
in
[
  {
    assertion = builtins.length dnsDomains == builtins.length (lib.unique dnsDomains);
    message = "site DNS records must use unique domains";
  }
  {
    assertion = lib.all (network: builtins.elem network.gateway.host knownHosts) wireguardNetworks;
    message = "WireGuard servers must reference known fleet hosts";
  }
  {
    assertion = lib.all (host: builtins.elem host knownHosts) registeredPeerHosts;
    message = "WireGuard clients must reference known fleet hosts";
  }
  {
    assertion = builtins.length registeredPeerHosts == builtins.length (lib.unique registeredPeerHosts);
    message = "Fleet hosts may be registered as a WireGuard client only once";
  }
  {
    assertion = lib.all (
      network:
      let
        addresses = map (peer: peer.address) (builtins.attrValues network.peers);
      in
      builtins.length addresses == builtins.length (lib.unique addresses)
    ) wireguardNetworks;
    message = "WireGuard peers must use unique addresses within each network";
  }
]
