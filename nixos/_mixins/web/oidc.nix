{ config, lib, ... }:
let
  services = config.host.web.services;
  oidcServices = lib.filterAttrs (_: service: service.auth.oidcRegistration != null) services;
in
{
  config = lib.mkIf (oidcServices != { }) {
    host.sso.oidc.registrations = lib.mapAttrs' (
      serviceName: service: lib.nameValuePair serviceName service.auth.oidcRegistration
    ) oidcServices;
  };
}
