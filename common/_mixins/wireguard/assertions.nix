{
  config,
  ...
}:
let
  server = config.host.wireguard.server;
  client = config.host.wireguard.client;
in
{
  assertions = [
    {
      assertion = client == null || builtins.hasAttr client.network config.host.wireguard.networks;
      message = "WireGuard client references a network without a server: ${
        if client == null then "" else client.network
      }";
    }
    {
      assertion = server == null || builtins.hasAttr server.network config.host.wireguard.networks;
      message = "WireGuard server inventory has no normalized network";
    }
  ];
}
