{ config, lib, ... }:
let
  cfg = config.host.site;
  ip = import ../../_lib/ipv4.nix { inherit lib; };
  reservations = builtins.attrValues cfg.lan.reservations;
in
{
  config.assertions = [
    {
      assertion = cfg.policies.backups.maxUploadMbit <= cfg.uplink.uploadMbit;
      message = "site '${cfg.name}' backup policy must not exceed its upload capacity";
    }
    {
      assertion = cfg.policies.downloaders.maxDownloadMbit <= cfg.uplink.downloadMbit;
      message = "site '${cfg.name}' downloader policy must not exceed its download capacity";
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
