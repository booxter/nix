{
  addressFor,
  fleetServices,
  lanDomain,
  ttlSeconds ? 300,
}:
let
  mkRecord = domain: hostName: {
    type = "A_RECORD";
    inherit domain;
    ipv4Address = addressFor hostName;
    inherit ttlSeconds;
  };
  internalRecords =
    map (contribution: mkRecord contribution.value.internal.serverName contribution.owner)
      (
        builtins.filter (
          contribution:
          contribution.value.internal != null
          && builtins.match ".*[.].*" contribution.value.internal.serverName != null
        ) fleetServices.contributions
      );
  # UniFi's A-only overrides expose the public CNAME through AAAA queries.
  # A local alias keeps every query type pointed at the LAN hostname instead.
  publicRecords = map (contribution: {
    type = "CNAME_RECORD";
    domain = contribution.value.public.hostName;
    targetDomain = "${contribution.value.public.splitDnsHost}.${lanDomain}";
    inherit ttlSeconds;
  }) fleetServices.public;
in
internalRecords ++ publicRecords
