{
  config,
  facts,
  lib,
  outputs,
}:
let
  hostName = config.networking.hostName;
  siteName = config.host.site.name;
  localNetwork = {
    inherit siteName;
    controller = {
      inherit (config.host.network.ipController) enable flavor target;
    };
    inherit (config.host.network) macAddress reservation;
  };
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ hostName ];
  networksByHost =
    lib.mapAttrs (_: configuration: {
      siteName = configuration.config.host.site.name;
      controller = {
        inherit (configuration.config.host.network.ipController) enable flavor target;
      };
      inherit (configuration.config.host.network) macAddress reservation;
    }) otherConfigurations
    // {
      ${hostName} = localNetwork;
    };
  controllers =
    lib.mapAttrs
      (name: network: {
        provider = name;
        inherit (network.controller) flavor target;
      })
      (
        lib.filterAttrs (
          _: network: network.siteName == siteName && network.controller.enable
        ) networksByHost
      );
  controller = if controllers == { } then null else builtins.head (builtins.attrValues controllers);
  managedReservations = lib.mapAttrsToList (name: network: {
    hostname = name;
    ip = network.reservation.address;
    identifiers = lib.optional (network.macAddress != null) network.macAddress;
  }) (lib.filterAttrs (_: network: network.reservation.enable) networksByHost);
  reservations = managedReservations ++ facts.site.lan.reservations;
in
{
  inherit
    controller
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
