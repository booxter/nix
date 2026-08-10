{
  config,
  facts,
  ...
}:
let
  endpointName = "${config.networking.hostName}-luks";
in
{
  assertions = [
    {
      assertion =
        !config.host.luks.remoteUnlock.enable || builtins.hasAttr endpointName facts.public-keys.hosts;
      message = "host.luks.remoteUnlock requires public key facts.public-keys.hosts.${endpointName}";
    }
  ];
}
