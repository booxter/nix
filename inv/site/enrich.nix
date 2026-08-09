{
  hosts,
  lanDnsRecordTtlSeconds,
  lanDomain,
  lib,
}:
facts:
let
  mkDnsARecord = domain: ipv4Address: {
    type = "A_RECORD";
    ttlSeconds = lanDnsRecordTtlSeconds;
    inherit domain ipv4Address;
  };
  staticDnsRecords = [
    (mkDnsARecord "unifi.${lanDomain}" facts.lan.gateway.address)
  ];
  renderHostDnsRecords =
    spec:
    (map (domain: mkDnsARecord domain (hosts.toHostIpv4Address spec)) (spec.dnsAliases or [ ]))
    ++ map (label: mkDnsARecord "${label}.${lanDomain}" (hosts.toHostIpv4Address spec)) (
      lib.unique (spec.localDnsAliases or [ ])
    );
in
facts
// {
  lan = facts.lan // {
    staticRoutes = [
      {
        destination = facts.wireguard.home.cidr;
        nextHop = hosts.toNixosHostIpv4Address facts.wireguard.home.gateway.host;
        distance = 1;
        name = "wg-home";
      }
    ];
    dnsRecords = staticDnsRecords ++ builtins.concatMap renderHostDnsRecords hosts.nixosHostSpecs;
  };
}
