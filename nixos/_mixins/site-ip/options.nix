{
  config,
  lib,
  ...
}:
let
  cfg = config.host.network;
  reservation = config.host.site.lan.reservations.${config.networking.hostName} or null;
in
{
  options.host.network = {
    macAddress = lib.mkOption {
      type = with lib.types; nullOr (strMatching "([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}");
      default = if reservation == null then null else reservation.macAddress;
      description = "MAC address of the host's primary site network interface.";
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
      default = if reservation == null then null else reservation.address;
      description = "Stable site IPv4 address derived from this host's reservation.";
    };

    ipController = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule { });
      default = null;
      description = "Make this host reconcile the site UniFi IP controller.";
    };
  };

  config.assertions = [
    {
      assertion = cfg.stableAddress.requiredBy == [ ] || reservation != null;
      message = "${config.networking.hostName} requires a stable site address for: ${lib.concatStringsSep ", " (lib.unique cfg.stableAddress.requiredBy)}";
    }
    {
      assertion = reservation == null || cfg.stableAddress.requiredBy != [ ];
      message = "${config.networking.hostName} has a site IP reservation without a stable-address requirement";
    }
  ];
}
