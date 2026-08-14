{
  config,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.network;
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
  imports = [
    ./assertions.nix
    ./unifi
  ];

  options.host.network = {
    macAddress = lib.mkOption {
      type = with lib.types; nullOr (strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}");
      default = null;
      description = "MAC address of the host's primary site network interface.";
    };

    reservation = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options.address = lib.mkOption {
            type = addCheck nonEmptyStr ip.validIpv4;
            description = "IPv4 address requested from the site IP controller.";
          };
        });
      default = null;
      description = "Optional site IPv4 address reservation.";
    };

    stableAddress.requiredBy = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = [ ];
      internal = true;
      description = "Relationships that require this host to retain a stable site address.";
    };

    ipAddress = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      readOnly = true;
      default = if cfg.reservation == null then null else cfg.reservation.address;
      description = "Stable site IPv4 address derived from this host's reservation.";
    };

    ipController = lib.mkOption {
      type = with lib.types; nullOr (enum [ "unifi" ]);
      default = null;
      description = "IP controller implementation reconciled by this host.";
    };

    ipReservations = lib.mkOption {
      type = with lib.types; listOf attrs;
      readOnly = true;
      default = if cfg.ipController == null then [ ] else model.reservations;
      internal = true;
      description = "Site reservations rendered for the local IP controller reconciler.";
    };
  };
}
