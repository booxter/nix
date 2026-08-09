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

  localNetwork = {
    inherit (cfg) ipAddress ipController reservation;
  };
  otherConfigurations = removeAttrs outputs.nixosConfigurations [ hostName ];
  networksByHost =
    lib.mapAttrs (_: configuration: {
      inherit (configuration.config.host.network) ipAddress ipController reservation;
    }) otherConfigurations
    // {
      ${hostName} = localNetwork;
    };
  controllers = lib.filterAttrs (_: network: network.ipController.enable) networksByHost;
  managedReservations = lib.mapAttrsToList (name: network: {
    hostname = name;
    ip = network.reservation.address;
    inherit (network.reservation) identifiers;
  }) (lib.filterAttrs (_: network: network.reservation.enable) networksByHost);
  reservations = managedReservations ++ lan.reservations;

  reservationAddresses = map (reservation: reservation.ip) reservations;
  reservationHostnames = map (reservation: reservation.hostname) reservations;
  reservationIdentifiers = builtins.concatLists (
    map (reservation: reservation.identifiers) reservations
  );

  validIpv4 =
    address:
    let
      parts = lib.splitString "." address;
    in
    builtins.length parts == 4
    && lib.all (part: builtins.match "(0|[1-9][0-9]{0,2})" part != null) parts
    && lib.all (part: builtins.fromJSON part <= 255) parts;
  ipv4ToInt =
    address:
    lib.foldl' (result: part: result * 256 + builtins.fromJSON part) 0 (lib.splitString "." address);
  inCidr =
    cidr: address:
    let
      cidrParts = lib.splitString "/" cidr;
      network = builtins.elemAt cidrParts 0;
      prefixLength = builtins.fromJSON (builtins.elemAt cidrParts 1);
      hostBits = 32 - prefixLength;
      blockSize = lib.foldl' (result: _: result * 2) 1 (builtins.genList (_: null) hostBits);
    in
    validIpv4 address
    && builtins.div (ipv4ToInt address) blockSize == builtins.div (ipv4ToInt network) blockSize;
in
{
  options.host.network = {
    reservation = {
      enable = lib.mkEnableOption "a site IPv4 address reservation";

      address = lib.mkOption {
        type = with lib.types; nullOr nonEmptyStr;
        default = null;
        description = "IPv4 address requested from the site IP controller.";
      };

      identifiers = lib.mkOption {
        type = with lib.types; listOf nonEmptyStr;
        default = [ ];
        description = "Client identifiers, normally MAC addresses, used for the reservation.";
      };
    };

    ipAddress = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      readOnly = true;
      default = if cfg.reservation.enable then cfg.reservation.address else null;
      description = "Stable site IPv4 address derived from this host's reservation.";
    };

    ipController = {
      enable = lib.mkEnableOption "the site IP allocation controller";

      reservations = lib.mkOption {
        type = with lib.types; listOf attrs;
        readOnly = true;
        default = if cfg.ipController.enable then reservations else [ ];
        description = "Validated managed and unmanaged site reservations.";
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = lib.optionals cfg.reservation.enable [
        {
          assertion = cfg.reservation.address != null;
          message = "host.network.reservation.address must be set when the reservation is enabled";
        }
        {
          assertion = cfg.reservation.identifiers != [ ];
          message = "host.network.reservation.identifiers must not be empty when the reservation is enabled";
        }
        {
          assertion = cfg.reservation.address != null && validIpv4 cfg.reservation.address;
          message = "host.network.reservation.address must be a valid IPv4 address";
        }
        {
          assertion = cfg.reservation.address != null && inCidr lan.cidr cfg.reservation.address;
          message = "host.network.reservation.address must belong to the site LAN ${lan.cidr}";
        }
      ];
    }

    (lib.mkIf cfg.ipController.enable {
      assertions = [
        {
          assertion = builtins.length (builtins.attrNames controllers) == 1;
          message = "exactly one NixOS host must enable host.network.ipController";
        }
        {
          assertion =
            builtins.length reservationHostnames == builtins.length (lib.unique reservationHostnames);
          message = "site IP reservation hostnames must be unique";
        }
        {
          assertion =
            builtins.length reservationAddresses == builtins.length (lib.unique reservationAddresses);
          message = "site IP reservation addresses must be unique";
        }
        {
          assertion =
            builtins.length reservationIdentifiers == builtins.length (lib.unique reservationIdentifiers);
          message = "site IP reservation identifiers must be unique";
        }
        {
          assertion = lib.all (reservation: inCidr lan.cidr reservation.ip) reservations;
          message = "all site IP reservations must belong to the site LAN ${lan.cidr}";
        }
      ];
    })
  ];
}
