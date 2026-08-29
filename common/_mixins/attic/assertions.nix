{ config, ... }:
{
  assertions = [
    {
      assertion =
        !config.host.attic.server.enable
        || config.host.attic.server.endpoint == null
        || config.host.attic.server.trustedPublicKey != null;
      message = "Attic server '${config.networking.hostName}' must declare its Nix signing public key";
    }
    {
      assertion =
        !config.host.attic.server.enable
        || config.host.attic.server.endpoint == null
        || config.host.attic.server.endpoint == config.host.web.services.atticd.internal.url;
      message = "Attic server '${config.networking.hostName}' inventory endpoint must match its internal web URL";
    }
  ];
}
