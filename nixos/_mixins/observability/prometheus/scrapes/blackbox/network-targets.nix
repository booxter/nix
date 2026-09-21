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
      probe_protocol = "icmp";
      probe_title = "Gateway ${gatewayAddress}";
      target = gatewayAddress;
    }
    {
      probe = "cloudflare";
      probe_protocol = "icmp";
      probe_title = "Cloudflare 1.1.1.1";
      target = "1.1.1.1";
    }
  ];

  wanTcpProbeTargets = [
    {
      probe = "gateway-dns";
      probe_protocol = "tcp";
      probe_title = "Gateway DNS ${gatewayAddress}:53";
      target = "${gatewayAddress}:53";
    }
    {
      probe = "cloudflare-https";
      probe_protocol = "tcp";
      probe_title = "Cloudflare 1.1.1.1:443";
      target = "1.1.1.1:443";
    }
  ];

  wanDnsProbeTargets = [
    {
      probe = "cloudflare-dns";
      probe_protocol = "dns";
      probe_title = "Cloudflare DNS 1.1.1.1:53";
      target = "1.1.1.1:53";
    }
  ];

  wanHttpProbeTargets = [
    {
      probe = "example-http";
      probe_protocol = "http";
      probe_title = "Example.com HTTPS";
      target = "https://example.com/";
    }
  ];
}
