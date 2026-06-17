{
  hostInventory,
  ...
}:
let
  wgHome = hostInventory.site.wireguard.home;
  wgInterface = "wg0";
  wgExporterInternalAddress = "127.0.0.1";
  wgExporterInternalPort = 9587;
  wgExporterPublicAddress = hostInventory.toNixosHostIpv4Address wgHome.gateway.host;
  wgExporterPublicHost = "gw.${hostInventory.site.lan.domain}";
  wgExporterPublicPort = 9586;
in
{
  host.observability.client.prometheusMtlsEndpoints."wg-home" = {
    enable = true;
    listenAddress = wgExporterPublicAddress;
    port = wgExporterPublicPort;
    path = "/metrics";
    upstream = "http://${wgExporterInternalAddress}:${toString wgExporterInternalPort}/metrics";
    serverName = wgExporterPublicHost;
    secretPrefix = "prometheus/wg-home";
  };

  services.prometheus.exporters.wireguard = {
    enable = true;
    listenAddress = wgExporterInternalAddress;
    port = wgExporterInternalPort;
    interfaces = [ wgInterface ];
    withRemoteIp = true;
    latestHandshakeDelay = true;
    openFirewall = false;
  };

  systemd.services.prometheus-wireguard-exporter = {
    wants = [
      "network-online.target"
      "wireguard-${wgInterface}.service"
    ];
    after = [
      "network-online.target"
      "wireguard-${wgInterface}.service"
    ];
  };
}
