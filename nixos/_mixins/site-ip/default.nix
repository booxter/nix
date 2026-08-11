{
  config,
  facts,
  lib,
  outputs,
  ...
}:
let
  cfg = config.host.network;
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

    reservation = {
      enable = lib.mkEnableOption "a site IPv4 address reservation";

      address = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "IPv4 address requested from the site IP controller.";
      };
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
      default = if cfg.reservation.enable then cfg.reservation.address else null;
      description = "Stable site IPv4 address derived from this host's reservation.";
    };

    ipController = {
      enable = lib.mkEnableOption "the site IP allocation controller";

      flavor = lib.mkOption {
        type = with lib.types; nullOr (enum [ "unifi" ]);
        default = null;
        description = "IP controller implementation used to reconcile site network state.";
      };

      reservations = lib.mkOption {
        type = with lib.types; listOf attrs;
        readOnly = true;
        default = if cfg.ipController.enable then model.reservations else [ ];
        description = "Validated managed and unmanaged site reservations.";
      };
    };
  };
}
