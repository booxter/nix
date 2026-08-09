{ lib }:
facts:
let
  names = builtins.attrNames facts.darwinHosts ++ map (spec: spec.name) facts.nixosHostSpecs;
  reservationNames = map (reservation: reservation.hostname) (
    facts.managedDhcpReservations ++ facts.staticDhcpReservations
  );
in
[
  {
    assertion = builtins.length names == builtins.length (lib.unique names);
    message = "host names must be unique";
  }
  {
    assertion = builtins.length reservationNames == builtins.length (lib.unique reservationNames);
    message = "DHCP reservation hostnames must be unique";
  }
]
