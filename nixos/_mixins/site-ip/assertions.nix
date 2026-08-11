{
  config,
  facts,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.network;
  hostName = config.networking.hostName;
  lan = facts.site.lan;
  ip = import ./lib.nix { inherit lib; };
  model = import ./model.nix {
    inherit
      config
      facts
      lib
      outputs
      ;
  };
in
{
  config.assertions =
    lib.optionals cfg.reservation.enable [
      {
        assertion = cfg.reservation.address != null;
        message = "host.network.reservation.address must be set when the reservation is enabled";
      }
      {
        assertion = cfg.macAddress != null;
        message = "host.network.macAddress must be set when the reservation is enabled";
      }
      {
        assertion = cfg.reservation.address != null && ip.validIpv4 cfg.reservation.address;
        message = "host.network.reservation.address must be a valid IPv4 address";
      }
      {
        assertion = cfg.reservation.address != null && ip.inCidr lan.cidr cfg.reservation.address;
        message = "host.network.reservation.address must belong to the site LAN ${lan.cidr}";
      }
    ]
    ++ [
      {
        assertion = cfg.stableAddress.requiredBy == [ ] || cfg.reservation.enable;
        message = "${hostName} requires a stable site address for: ${lib.concatStringsSep ", " (lib.unique cfg.stableAddress.requiredBy)}";
      }
      {
        assertion = !cfg.reservation.enable || cfg.stableAddress.requiredBy != [ ];
        message = "${hostName} declares a site IP reservation without a stable-address requirement";
      }
    ]
    ++ lib.optionals cfg.ipController.enable [
      {
        assertion = cfg.ipController.flavor != null;
        message = "host.network.ipController.flavor must be set when the controller is enabled";
      }
      {
        assertion = builtins.length (builtins.attrNames model.controllers) == 1;
        message = "exactly one NixOS host must enable host.network.ipController";
      }
      {
        assertion =
          builtins.length model.reservationHostnames
          == builtins.length (lib.unique model.reservationHostnames);
        message = "site IP reservation hostnames must be unique";
      }
      {
        assertion =
          builtins.length model.reservationAddresses
          == builtins.length (lib.unique model.reservationAddresses);
        message = "site IP reservation addresses must be unique";
      }
      {
        assertion =
          builtins.length model.reservationIdentifiers
          == builtins.length (lib.unique model.reservationIdentifiers);
        message = "site IP reservation identifiers must be unique";
      }
      {
        assertion = lib.all (reservation: reservation.identifiers != [ ]) model.reservations;
        message = "all site IP reservations must declare a client identifier";
      }
      {
        assertion = lib.all (reservation: ip.inCidr lan.cidr reservation.ip) model.reservations;
        message = "all site IP reservations must belong to the site LAN ${lan.cidr}";
      }
    ];
}
