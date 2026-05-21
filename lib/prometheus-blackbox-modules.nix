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

  http_service = {
    http = {
      follow_redirects = true;
      preferred_ip_protocol = "ip4";
    };
    prober = "http";
    timeout = "5s";
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
