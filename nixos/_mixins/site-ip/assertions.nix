{
  config,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.network;
  hostName = config.networking.hostName;
  lan = config.host.site.lan;
  ip = import ./lib.nix { inherit lib; };
  model = import ./model.nix {
    inherit
      config
      lib
      outputs
      ;
  };
in
{
  config.assertions =
    lib.optionals (cfg.reservation != null) [
      {
        assertion = cfg.macAddress != null;
        message = "host.network.macAddress must be set with host.network.reservation";
      }
      {
        assertion = ip.inCidr lan.cidr cfg.reservation.address;
        message = "host.network.reservation.address must belong to the site LAN ${lan.cidr}";
      }
    ]
    ++ [
      {
        assertion = cfg.stableAddress.requiredBy == [ ] || cfg.reservation != null;
        message = "${hostName} requires a stable site address for: ${lib.concatStringsSep ", " (lib.unique cfg.stableAddress.requiredBy)}";
      }
      {
        assertion = cfg.reservation == null || cfg.stableAddress.requiredBy != [ ];
        message = "${hostName} declares a site IP reservation without a stable-address requirement";
      }
    ]
    ++ lib.optionals (cfg.ipController != null) [
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
