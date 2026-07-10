{ ... }:
{
  host.fleetCacheWarmer = {
    enable = true;
    targetFilter = "work";
    pushToAttic = false;
    useRemoteBuilders = true;
  };
}
