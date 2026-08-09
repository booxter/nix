{ lib }:
raw:
let
  names = builtins.attrNames raw.darwin ++ builtins.attrNames raw.nixos;
  reservationNames = map (reservation: reservation.hostname) (
    raw.managedDhcpReservations ++ raw.staticDhcpReservations
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
