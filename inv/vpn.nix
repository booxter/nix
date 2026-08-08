{ lanCidr }:
{
  airvpn = {
    host = "srvarr";
    namespace = "wg";
    endpointPort = 1637;
    bridgeAddress = "192.168.50.5";
    namespaceAddress = "192.168.50.1";
    accessibleFrom = [
      "127.0.0.1"
      lanCidr
      "10.0.0.0/8"
    ];

    # TODO: Materialize this static profile through sops-nix.
    wireguardConfigFile = "/data/.secret/vpn/wg.conf";
  };
}
