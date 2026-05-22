{
  hostInventory,
  grafanaProbeUrl ? "http://127.0.0.1:3000/",
  srvarrPorts,
}:
let
  renderService =
    service:
    if service.scope == "external" then
      service
    else if service.owner == "fana" then
      service
      // {
        probeUrl = "${grafanaProbeUrl}${service.probePath}";
        url = "http://${service.displayHost}:3000/";
      }
    else
      service
      // {
        probeUrl = "http://${service.probeHost}:${toString srvarrPorts.${service.id}}${service.probePath}";
        url = "http://${service.displayHost}:${toString srvarrPorts.${service.id}}/";
      };
in
map renderService hostInventory.services
