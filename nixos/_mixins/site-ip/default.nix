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
  resolvedControllerType = lib.types.submodule {
    options = {
      provider = lib.mkOption {
        type = lib.types.nonEmptyStr;
      };
      flavor = lib.mkOption {
        type = with lib.types; nullOr (enum [ "unifi" ]);
      };
      target = {
        endpoint = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
        };
        site = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
        };
      };
    };
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

    ipController = {
      enable = lib.mkEnableOption "the site IP allocation controller";

      flavor = lib.mkOption {
        type = with lib.types; nullOr (enum [ "unifi" ]);
        default = null;
        description = "IP controller implementation used to reconcile site network state.";
      };

      target = {
        endpoint = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "API endpoint of the site network controller being reconciled.";
        };

        site = lib.mkOption {
          type = with lib.types; nullOr nonEmptyStr;
          default = null;
          description = "Controller-local site identifier being reconciled.";
        };
      };

      resolved = lib.mkOption {
        type = with lib.types; nullOr resolvedControllerType;
        default = model.controller;
        readOnly = true;
        internal = true;
        description = "IP controller provider and target resolved for this physical site.";
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
