{ config, lib, ... }:
let
  services = config.host.web.services;
  oauth2ProxyServices = lib.filterAttrs (_: service: service.auth.oauth2ProxyGate != null) services;
in
{
  config = lib.mkIf (oauth2ProxyServices != { }) {
    host.sso.oauth2ProxyGates = lib.mapAttrs' (
      serviceName: service: lib.nameValuePair serviceName service.auth.oauth2ProxyGate
    ) oauth2ProxyServices;
  };
}
