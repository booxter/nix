{
  config,
  fleetInventory,
  ...
}:
let
  cfg = config.host.jellyfin;
  localInventory = fleetInventory.webServices.byOwner.${config.networking.hostName} or { };
  inventoryEnabled = localInventory ? jellyfin;
in
{
  config.assertions = [
    {
      assertion = (cfg != null) == inventoryEnabled;
      message = "Jellyfin enablement must match its web service inventory entry";
    }
  ];
}
