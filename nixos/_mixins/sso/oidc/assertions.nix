{ config, lib, ... }:
{
  assertions = lib.concatMap (registration: [
    {
      assertion = registration.originUrls != [ ];
      message = "OIDC client ${registration.clientId} must declare at least one origin URL.";
    }
    {
      assertion = registration.public == (registration.secret.sopsKey == null);
      message = "OIDC client ${registration.clientId} must declare a secret exactly when confidential.";
    }
  ]) (builtins.attrValues config.host.sso.oidc.registrations);
}
