{
  config,
  ...
}:
{
  assertions = [
    {
      assertion =
        !config.host.luks.remoteUnlock.enable || config.host.luks.remoteUnlock.publicKey != null;
      message = "host.luks.remoteUnlock.publicKey must be set when remote unlock is enabled";
    }
  ];
}
