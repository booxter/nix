let
  httpService = {
    http = {
      follow_redirects = true;
      preferred_ip_protocol = "ip4";
    };
    prober = "http";
    timeout = "5s";
  };
in
{
  dns_udp = {
    dns = {
      preferred_ip_protocol = "ip4";
      query_name = "example.com";
      query_type = "A";
      transport_protocol = "udp";
      valid_rcodes = [ "NOERROR" ];
    };
    prober = "dns";
    timeout = "5s";
  };

  http_service = httpService;

  http_service_409 = httpService // {
    http = httpService.http // {
      valid_status_codes = [ 409 ];
    };
  };

  icmp_ipv4 = {
    icmp.preferred_ip_protocol = "ip4";
    prober = "icmp";
    timeout = "3s";
  };

  tcp_connect_ipv4 = {
    prober = "tcp";
    tcp.preferred_ip_protocol = "ip4";
    timeout = "3s";
  };
}
