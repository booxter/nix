{ config, lib, ... }:
let
  cfg = config.host.site;
  ip = import ../../_lib/ipv4.nix { inherit lib; };
  reservations = builtins.attrValues cfg.lan.reservations;
  values = [
    cfg.timeZone
    cfg.uplink.downloadMbit
    cfg.uplink.uploadMbit
    cfg.policies.backups.maxUploadMbit
    cfg.policies.downloaders.maxDownloadMbit
    cfg.lan.cidr
    cfg.lan.gateway.host
    cfg.lan.gateway.address
  ];
  configured = value: value != null;
in
{
  config.assertions = [
    {
      assertion =
        if cfg.name == null then lib.all (value: !configured value) values else lib.all configured values;
      message = "host.site properties must all be configured exactly when host.site.name is set";
    }
  ]
  ++ lib.optionals (cfg.name != null && lib.all configured values) [
    {
      assertion = cfg.policies.backups.maxUploadMbit <= cfg.uplink.uploadMbit;
      message = "site '${cfg.name}' backup policy must not exceed its upload capacity";
    }
    {
      assertion = cfg.policies.downloaders.maxDownloadMbit <= cfg.uplink.downloadMbit;
      message = "site '${cfg.name}' downloader policy must not exceed its download capacity";
    }
    {
      assertion = cfg.lan.dhcp.ranges != { };
      message = "site '${cfg.name}' must declare at least one DHCP range";
    }
    {
      assertion =
        builtins.length reservations
        == builtins.length (lib.unique (map (reservation: reservation.address) reservations));
      message = "site '${cfg.name}' reservation addresses must be unique";
    }
    {
      assertion =
        builtins.length reservations
        == builtins.length (lib.unique (map (reservation: reservation.macAddress) reservations));
      message = "site '${cfg.name}' reservation MAC addresses must be unique";
    }
    {
      assertion = lib.all (reservation: ip.inCidr cfg.lan.cidr reservation.address) reservations;
      message = "site '${cfg.name}' reservations must belong to its LAN ${cfg.lan.cidr}";
    }
  ];
}
