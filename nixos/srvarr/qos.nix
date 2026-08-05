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
  wgUnitDepsBase = networkOnlineUnitDeps // {
    After = networkOnlineUnitDeps.After ++ [ "wg.service" ];
    BindsTo = [ "wg.service" ];
    PartOf = [ "wg.service" ];
  };
in
{
  host.observability.client.mtlsClients."jellyfin-upload-policy".enable = true;

  imports = [
    ../_mixins/wireguard-qos
    (import ./adaptive-upload-policy.nix {
      jellyfinExporterUrl = "https://${beastHostConfig.networking.hostName}:${toString beastJellyfinEndpoint.port}${beastJellyfinEndpoint.path}";
      fallbackUploadRateMbit = tuning.wgConservativeUploadRateMbit;
      inherit
        networkOnlineUnitDeps
        wgUnitDepsBase
        ;
    })
  ];

  host.wireguardQos = {
    enable = true;
    wireguardUnit = "wg.service";
    port = wgEndpointPort;
    egressPort = "destination";
    uploadRateMbit = tuning.wgConservativeUploadRateMbit;
    downloadRateMbit = 400;
    nfs = {
      address = beastNfsAddress;
      port = beastNfsPort;
      rateMbit = beastNfsRateMbit;
    };
  };

  host.observability.lanWan = {
    interface = "ens18";
    # nft postrouting overcounts the WireGuard transport on this host, so use
    # the shaped tc class as the authoritative WAN egress counter instead.
    wanTransmitTcClass = "1:10";
    wanUdpSubclass = {
      name = "wg";
      port = wgEndpointPort;
    };
  };

  # The native QoS module applies a conservative bidirectional WireGuard
  # baseline and caps NFS writes below this path's unstable single-flow
  # ceiling. The adaptive controller can still raise class 1:10 at runtime.
}
