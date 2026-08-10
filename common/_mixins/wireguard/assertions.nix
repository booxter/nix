{
  config,
  facts,
  lib,
  ...
}:
let
  hostname = config.networking.hostName;
  networks = builtins.attrValues facts.site.wireguard;
  ownedServers = builtins.filter (network: network.gateway.host == hostname) networks;
  ownedClients = builtins.filter (
    network: lib.any (peer: (peer.host or null) == hostname) (builtins.attrValues network.peers)
  ) networks;
in
{
  assertions = [
    {
      assertion = builtins.length ownedServers <= 1;
      message = "Host ${hostname} may serve at most one WireGuard network.";
    }
    {
      assertion = builtins.length ownedClients <= 1;
      message = "Host ${hostname} may join at most one WireGuard network.";
    }
  ];
}
