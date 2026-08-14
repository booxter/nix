{ config }:
let
  reservations = config.host.site.lan.reservations;
  addressFor =
    hostName:
    let
      reservation = reservations.${hostName} or (throw "unknown site host '${hostName}'");
    in
    reservation.address;
in
{
  inherit addressFor reservations;
}
