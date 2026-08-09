{
  fleetServices,
  hostInventory,
  ttlSeconds ? 300,
}:
let
  mkRecord = domain: hostName: {
    type = "A_RECORD";
    inherit domain;
    ipv4Address = hostInventory.toNixosHostIpv4Address hostName;
    inherit ttlSeconds;
  };
  internalRecords =
    map (contribution: mkRecord contribution.value.internal.serverName contribution.owner)
      (
        builtins.filter (
          contribution:
          contribution.value.internal.enable
          && builtins.match ".*[.].*" contribution.value.internal.serverName != null
        ) fleetServices.contributions
      );
  publicRecords = map (
    contribution: mkRecord contribution.value.public.hostName contribution.value.public.splitDnsHost
  ) fleetServices.public;
in
internalRecords ++ publicRecords
