{
  fleetInventory,
}:
let
  contributions = fleetInventory.webServices.contributions;
  publicContributions = builtins.filter (
    contribution: contribution.value.public != null
  ) contributions;
in
{
  inherit contributions;
  public = publicContributions;
  dashboard = builtins.filter (contribution: contribution.value.dashboard != null) contributions;
  frontendProbes = builtins.filter (
    contribution: contribution.value.health.frontend != null
  ) contributions;
  backendProbes = builtins.filter (
    contribution: contribution.value.health.backend != null
  ) contributions;
}
