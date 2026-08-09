{
  lib,
  realms,
}:
facts:
let
  realmFor =
    spec:
    let
      realmName = spec.realm or (throw "host ${spec.name} does not declare a realm");
    in
    realms.${realmName} or (throw "host ${spec.name} declares unknown realm '${realmName}'");
  normalizeHostSpec = spec: builtins.seq (realmFor spec) spec;
  darwinHosts = lib.mapAttrs (_: normalizeHostSpec) facts.darwinHosts;
  nixosHostSpecs = map normalizeHostSpec facts.nixosHostSpecs;
  managedDhcpReservations = map (spec: spec.dhcpReservation // { hostname = spec.name; }) (
    builtins.filter (spec: spec ? dhcpReservation) nixosHostSpecs
  );
  dhcpReservationsByHostname = builtins.listToAttrs (
    map (reservation: {
      name = reservation.hostname;
      value = reservation;
    }) (managedDhcpReservations ++ facts.staticDhcpReservations)
  );
  nixosHosts = builtins.listToAttrs (
    map (spec: {
      name = spec.name;
      value = spec;
    }) nixosHostSpecs
  );
  hostSpecsByName = darwinHosts // nixosHosts;
  aliasIpv4Address =
    spec:
    if spec ? dhcpReservation then
      spec.dhcpReservation.ip
    else if spec ? ipAddress then
      spec.ipAddress
    else
      throw "host ${spec.name} does not have a stable IPv4 address";
  toLocalDnsName = label: "${label}.local";
in
facts
// {
  inherit
    darwinHosts
    dhcpReservationsByHostname
    hostSpecsByName
    managedDhcpReservations
    nixosHosts
    nixosHostSpecs
    toLocalDnsName
    ;

  secretDomainsByHost = lib.mapAttrs (_: spec: (realmFor spec).secretDomain) hostSpecsByName;
  systemsByHost = lib.mapAttrs (_: spec: spec.platform) hostSpecsByName;

  toHostIpv4Address = aliasIpv4Address;
  toNixosHostIpv4Address = name: aliasIpv4Address nixosHosts.${name};
  toNixosHostCertificateDnsNames = domain: spec: [
    spec.name
    "${spec.name}.${domain}"
    (toLocalDnsName spec.name)
  ];
  toSshKnownHostNames =
    domain: spec:
    let
      inherit (spec) name;
      lowercaseName = lib.toLower name;
    in
    lib.unique (
      [ name ]
      ++ lib.optional (lowercaseName != name) lowercaseName
      ++ lib.optional (lib.hasSuffix "-linux" spec.platform) "${name}.${domain}"
      ++ [ (toLocalDnsName name) ]
      ++ lib.optional (lowercaseName != name) (toLocalDnsName lowercaseName)
    );
  toUpsName = name: "${lib.strings.toUpper name}-UPS";
}
