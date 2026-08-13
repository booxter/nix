{
  config,
  ...
}:
{
  host.seerr = {
    enable = true;
    stateDir = "/data/.state/nixarr/seerr";
    publicHostName = "js.${config.host.network.publicDomain}";
  };

  # TODO(seerr): revisit declarative settings reconciliation through Seerr's
  # public API once it has a reliable bootstrap/readiness contract. Do not
  # write its private database or inject Jellyfin API keys out of band.
}
