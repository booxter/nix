{
  context,
  facts,
  lib,
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
  renderHostDnsRecords =
    spec:
    (map (domain: mkDnsARecord domain spec.ipAddress) (spec.dnsAliases or [ ]))
    ++ map (label: mkDnsARecord "${label}.${lanDomain}" spec.ipAddress) (
      lib.unique (spec.localDnsAliases or [ ])
    );
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
    dnsRecords =
      staticDnsRecords ++ lib.concatMap renderHostDnsRecords (builtins.attrValues hosts.nixos);
  };
}
