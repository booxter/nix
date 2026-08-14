{
  config,
  lib,
  outputs,
}:
let
  hostName = config.networking.hostName;
  siteName = config.host.site.name;
  localNetwork = {
    inherit siteName;
    inherit (config.host.network) macAddress reservation;
  };
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ hostName ];
  networksByHost =
    lib.mapAttrs (_: configuration: {
      siteName = configuration.config.host.site.name;
      inherit (configuration.config.host.network) macAddress reservation;
    }) otherConfigurations
    // {
      ${hostName} = localNetwork;
    };
  managedReservations = lib.mapAttrsToList (name: network: {
    hostname = name;
    ip = network.reservation.address;
    identifiers = lib.optional (network.macAddress != null) network.macAddress;
  }) (lib.filterAttrs (_: network: network.reservation != null) networksByHost);
  unmanagedReservations = lib.mapAttrsToList (hostname: reservation: {
    inherit hostname;
    inherit (reservation) identifiers;
    ip = reservation.address;
  }) config.host.site.lan.reservations;
  reservations = managedReservations ++ unmanagedReservations;
in
{
  inherit
    managedReservations
    networksByHost
    reservations
    unmanagedReservations
    ;
  reservationAddresses = map (reservation: reservation.ip) reservations;
  reservationHostnames = map (reservation: reservation.hostname) reservations;
  reservationIdentifiers = builtins.concatLists (
    map (reservation: reservation.identifiers) reservations
  );
}
