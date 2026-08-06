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
  wgEndpointPort = 1637;
in
{
  services.adaptive-upload-policy = {
    enable = true;
    fallbackRateMbit = tuning.wgConservativeUploadRateMbit;
    source.jellyfin = {
      exporterUrl = "https://${beastHostConfig.networking.hostName}:${toString beastJellyfinEndpoint.port}${beastJellyfinEndpoint.path}";
      mtls = {
        enable = true;
        clientName = "jellyfin-upload-policy";
        secretPrefix = "prometheus/clients/jellyfin-upload-policy";
      };
    };
    outputs = {
      transmission.enable = true;
      qos = {
        enable = true;
        profile = "wan";
        limit = "wireguard-upload";
      };
    };
    group = "media";
  };

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
