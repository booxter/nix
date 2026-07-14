{ ... }:
{
  host.codex.mcp.maasJira.enable = true;

  host.fleetCacheWarmer = {
    enable = true;
    targetFilter = "work";
    pushToAttic = false;
  };
}
