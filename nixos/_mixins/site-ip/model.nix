{
  config,
  facts,
  lib,
  outputs,
}:
let
  hostName = config.networking.hostName;
  localNetwork = {
    controllerEnabled = config.host.network.ipController.enable;
    inherit (config.host.network) macAddress reservation;
  };
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ hostName ];
  networksByHost =
    lib.mapAttrs (_: configuration: {
      controllerEnabled = configuration.config.host.network.ipController.enable;
      inherit (configuration.config.host.network) macAddress reservation;
    }) otherConfigurations
    // {
      ${hostName} = localNetwork;
    };
  controllers = lib.filterAttrs (_: network: network.controllerEnabled) networksByHost;
  managedReservations = lib.mapAttrsToList (name: network: {
    hostname = name;
    ip = network.reservation.address;
    identifiers = lib.optional (network.macAddress != null) network.macAddress;
  }) (lib.filterAttrs (_: network: network.reservation.enable) networksByHost);
  reservations = managedReservations ++ facts.site.lan.reservations;
in
{
  inherit
    controllers
    managedReservations
    networksByHost
    reservations
    ;
  reservationAddresses = map (reservation: reservation.ip) reservations;
  reservationHostnames = map (reservation: reservation.hostname) reservations;
  reservationIdentifiers = builtins.concatLists (
    map (reservation: reservation.identifiers) reservations
  );
}
