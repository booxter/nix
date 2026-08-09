{
  context,
  facts,
  lib,
}:
raw:
let
  inherit (context) lanDomain;
  realms = facts.realms;
  realmFor =
    spec:
    let
      realmName = spec.realm or (throw "host ${spec.name} does not declare a realm");
    in
    realms.${realmName} or (throw "host ${spec.name} declares unknown realm '${realmName}'");
  normalizeHostSpec =
    spec:
    let
      validated = builtins.seq (realmFor spec) spec;
      lowercaseName = lib.toLower validated.name;
      ipAddress =
        if validated ? dhcpReservation then validated.dhcpReservation.ip else validated.ipAddress or null;
    in
    validated
    // lib.optionalAttrs (ipAddress != null) { inherit ipAddress; }
    // {
      localDnsName = "${validated.name}.local";
      sshKnownHostNames = lib.unique (
        [ validated.name ]
        ++ lib.optional (lowercaseName != validated.name) lowercaseName
        ++ lib.optional (lib.hasSuffix "-linux" validated.platform) "${validated.name}.${lanDomain}"
        ++ [ "${validated.name}.local" ]
        ++ lib.optional (lowercaseName != validated.name) "${lowercaseName}.local"
      );
    };
  normalizeNixosHostSpec =
    spec:
    let
      normalized = normalizeHostSpec spec;
    in
    normalized
    // {
      certificateDnsNames = [
        normalized.name
        "${normalized.name}.${lanDomain}"
        normalized.localDnsName
      ];
    };
  darwinHosts = lib.mapAttrs (_: normalizeHostSpec) raw.darwinHosts;
  nixosHostSpecs = map normalizeNixosHostSpec raw.nixosHostSpecs;
  managedDhcpReservations = map (spec: spec.dhcpReservation // { hostname = spec.name; }) (
    builtins.filter (spec: spec ? dhcpReservation) nixosHostSpecs
  );
  dhcpReservationsByHostname = builtins.listToAttrs (
    map (reservation: {
      name = reservation.hostname;
      value = reservation;
    }) (managedDhcpReservations ++ raw.staticDhcpReservations)
  );
  nixosHosts = builtins.listToAttrs (
    map (spec: {
      name = spec.name;
      value = spec;
    }) nixosHostSpecs
  );
  hostSpecsByName = darwinHosts // nixosHosts;
in
raw
// {
  inherit
    darwinHosts
    dhcpReservationsByHostname
    hostSpecsByName
    managedDhcpReservations
    nixosHosts
    nixosHostSpecs
    ;

  secretDomainsByHost = lib.mapAttrs (_: spec: (realmFor spec).secretDomain) hostSpecsByName;
  systemsByHost = lib.mapAttrs (_: spec: spec.platform) hostSpecsByName;
}
