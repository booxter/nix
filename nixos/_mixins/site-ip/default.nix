{
  config,
  lib,
  ...
}:
let
  cfg = config.host.network;
  ip = import ./lib.nix { inherit lib; };
  reservation = config.host.site.lan.reservations.${config.networking.hostName} or null;
in
{
  imports = [
    ./assertions.nix
    ./unifi
  ];

  options.host.network = {
    macAddress = lib.mkOption {
      type = with lib.types; nullOr (strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}");
      default = if reservation == null then null else reservation.macAddress;
      description = "MAC address of the host's primary site network interface.";
    };

    reservation = lib.mkOption {
      type =
        with lib.types;
        nullOr (submodule {
          options = {
            address = lib.mkOption {
              type = addCheck nonEmptyStr ip.validIpv4;
            };
            macAddress = lib.mkOption {
              type = strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}";
            };
          };
        });
      default = reservation;
      readOnly = true;
      internal = true;
      description = "This host's reservation from the authoritative site inventory.";
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

  };
}
