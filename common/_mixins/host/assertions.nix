{
  config,
  hostSpec,
  lib,
  pkgs,
  ...
}:
let
  system = pkgs.stdenv.hostPlatform.system;
  isDarwin = lib.hasSuffix "-darwin" system;
  isLinux = lib.hasSuffix "-linux" system;
in
{
  assertions = [
    {
      assertion = isDarwin != isLinux;
      message = "Facts platform ${system} must identify exactly one supported kernel.";
    }
    {
      assertion = !config.host.isSecretsOperator || config.host.hasHardwareAgeIdentity;
      message = "Secrets operator ${hostSpec.name} must have a hardware-backed age identity.";
    }
  ];
}
