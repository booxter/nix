{
  context,
  facts,
}:
raw:
let
  inherit (context) lanDnsRecordTtlSeconds lanDomain;
  hosts = facts.hosts;
  mkDnsARecord = domain: ipv4Address: {
    type = "A_RECORD";
    ttlSeconds = lanDnsRecordTtlSeconds;
    inherit domain ipv4Address;
  };
  staticDnsRecords = [
    (mkDnsARecord "unifi.${lanDomain}" raw.lan.gateway.address)
  ];
in
raw
// {
  lan = raw.lan // {
    staticRoutes = [
      {
        destination = raw.wireguard.home.cidr;
        nextHop = hosts.nixos.${raw.wireguard.home.gateway.host}.ipAddress;
        distance = 1;
        name = "wg-home";
      }
    ];
    dnsRecords = staticDnsRecords;
  };
}
