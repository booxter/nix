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
    isLinux: spec:
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
        ++ lib.optional isLinux "${validated.name}.${lanDomain}"
        ++ [ "${validated.name}.local" ]
        ++ lib.optional (lowercaseName != validated.name) "${lowercaseName}.local"
      );
    };
  normalizeNixosHostSpec =
    spec:
    let
      normalized = normalizeHostSpec true spec;
    in
    normalized
    // {
      certificateDnsNames = [
        normalized.name
        "${normalized.name}.${lanDomain}"
        normalized.localDnsName
      ];
    };
  darwin = lib.mapAttrs (_: normalizeHostSpec false) raw.darwin;
  nixosSpecs = map normalizeNixosHostSpec raw.nixos;
  nixosNames = map (spec: spec.name) nixosSpecs;
  managedDhcpReservations = map (spec: spec.dhcpReservation // { hostname = spec.name; }) (
    builtins.filter (spec: spec ? dhcpReservation) nixosSpecs
  );
  dhcpReservationsByHostname = builtins.listToAttrs (
    map (reservation: {
      name = reservation.hostname;
      value = reservation;
    }) (managedDhcpReservations ++ raw.staticDhcpReservations)
  );
  nixos =
    assert lib.assertMsg (
      builtins.length nixosNames == builtins.length (lib.unique nixosNames)
    ) "NixOS host names must be unique";
    builtins.listToAttrs (
      map (spec: {
        name = spec.name;
        value = spec;
      }) nixosSpecs
    );
  hostSpecsByName = darwin // nixos;
in
raw
// {
  inherit
    darwin
    dhcpReservationsByHostname
    hostSpecsByName
    managedDhcpReservations
    nixos
    ;

  secretDomainsByHost = lib.mapAttrs (_: spec: (realmFor spec).secretDomain) hostSpecsByName;
}
