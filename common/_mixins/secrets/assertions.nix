{
  config,
  lib,
  ...
}:
let
  identity = config.host.secrets.operatorAgeIdentity;
  usesSecureEnclave = identity != null && identity.backend == "secure-enclave";
  usesYubiKey = identity != null && identity.backend == "yubikey";
in
{
  assertions = [
    {
      assertion = !config.host.isSecretsOperator || identity != null;
      message = "Secrets operator ${config.networking.hostName} must declare a hardware-backed age identity.";
    }
    {
      assertion = identity == null || config.host.isSecretsOperator;
      message = "Only secrets operators may declare host.secrets.operatorAgeIdentity.";
    }
    {
      assertion = !usesSecureEnclave || (config.host.isDarwin && config.host.hardware.hasTouchId);
      message = "Secure Enclave age identities require a Darwin host with Touch ID.";
    }
    {
      assertion = !usesYubiKey || config.host.hasYubiAgeIdentity;
      message = "YubiKey age identities must be assigned to the host in YubiKey facts.";
    }
    {
      assertion = identity == null || lib.hasPrefix "/" identity.path;
      message = "host.secrets.operatorAgeIdentity.path must be absolute.";
    }
  ];
}
