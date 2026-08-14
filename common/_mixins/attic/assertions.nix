{ config, ... }:
{
  assertions = [
    {
      assertion = !config.host.attic.server.enable || config.host.attic.server.endpoint != null;
      message = "Attic server '${config.networking.hostName}' must declare its client endpoint";
    }
    {
      assertion = !config.host.attic.server.enable || config.host.attic.server.trustedPublicKey != null;
      message = "Attic server '${config.networking.hostName}' must declare its Nix signing public key";
    }
  ];
}
