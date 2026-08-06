{
  config,
  hostInventory,
  outputs,
  ...
}:
let
  tuning = config.host.srvarrTuning;
  beastNfsAddress = hostInventory.dhcpReservationsByHostname.beast.ip;
  beastHostConfig = outputs.nixosConfigurations.beast.config;
  beastJellyfinEndpoint = beastHostConfig.host.observability.client.prometheusMtlsEndpoints.jellyfin;
  beastNfsPort = hostInventory.site.ports.nfs;
  beastNfsRateMbit = 1500;
  networkOnlineUnitDeps = {
    Wants = [ "network-online.target" ];
    After = [ "network-online.target" ];
  };
  wgEndpointPort = 1637;
in
{
  host.observability.client.mtlsClients."jellyfin-upload-policy".enable = true;

  imports = [
    (import ./adaptive-upload-policy.nix {
      jellyfinExporterUrl = "https://${beastHostConfig.networking.hostName}:${toString beastJellyfinEndpoint.port}${beastJellyfinEndpoint.path}";
      fallbackUploadRateMbit = tuning.wgConservativeUploadRateMbit;
      inherit networkOnlineUnitDeps;
    })
  ];

  host.qos.interfaces.wan = {
    device = "ens18";
    limits = {
      nfs = {
        rateMbit = beastNfsRateMbit;
        match = {
          protocol = "tcp";
          destinationAddress = beastNfsAddress;
          destinationPort = beastNfsPort;
        };
      };
      wireguard-download = {
        direction = "ingress";
        rateMbit = 400;
        match = {
          protocol = "udp";
          sourcePort = wgEndpointPort;
        };
      };
      wireguard-upload = {
        rateMbit = tuning.wgConservativeUploadRateMbit;
        queue = "cake";
        match = {
          protocol = "udp";
          destinationPort = wgEndpointPort;
        };
      };
    };
  };

  host.observability.lanWan = {
    interface = "ens18";
    # nft postrouting overcounts the WireGuard transport on this host, so use
    # the shaped tc class as the authoritative WAN egress counter instead.
    wanTransmitTcClass = config.host.qos.classIds.wan.wireguard-upload;
    wanUdpSubclass = {
      name = "wg";
      port = wgEndpointPort;
    };
  };

}
