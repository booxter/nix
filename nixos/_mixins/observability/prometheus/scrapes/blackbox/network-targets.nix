{ config }:
let
  gatewayAddress = config.host.site.lan.gateway.address;
in
{
  dnsProbeTargets = [
    {
      resolver = "gateway";
      resolver_title = "gateway ${gatewayAddress}";
      target = "${gatewayAddress}:53";
    }
    {
      resolver = "google";
      resolver_title = "Google 8.8.8.8";
      target = "8.8.8.8:53";
    }
  ];

  publicDnsProbeTargets = [
    {
      resolver = "cloudflare";
      resolver_title = "Cloudflare 1.1.1.1";
      target = "1.1.1.1:53";
    }
    {
      resolver = "google";
      resolver_title = "Google 8.8.8.8";
      target = "8.8.8.8:53";
    }
  ];

  wanIcmpProbeTargets = [
    {
      probe = "gateway";
      probe_title = "Gateway ${gatewayAddress}";
      target = gatewayAddress;
    }
    {
      probe = "cloudflare";
      probe_title = "Cloudflare 1.1.1.1";
      target = "1.1.1.1";
    }
  ];

  wanTcpProbeTargets = [
    {
      probe = "gateway-dns";
      probe_title = "Gateway DNS ${gatewayAddress}:53";
      target = "${gatewayAddress}:53";
    }
    {
      probe = "cloudflare-https";
      probe_title = "Cloudflare 1.1.1.1:443";
      target = "1.1.1.1:443";
    }
  ];
}
