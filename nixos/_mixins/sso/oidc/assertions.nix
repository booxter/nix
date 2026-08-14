{ config, lib, ... }:
{
  assertions = lib.mapAttrsToList (clientId: registration: {
    assertion = registration.originUrls != [ ];
    message = "OIDC client ${clientId} must declare at least one origin URL.";
  }) config.host.sso.oidc.registrations;
}
