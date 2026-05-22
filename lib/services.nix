{
  hostInventory,
  grafanaDisplayUrl ? "http://fana.local:3000/",
  grafanaProbeUrl ? "http://127.0.0.1:3000/",
  srvarrDisplayHost ? "srvarr.local",
  srvarrProbeHost ? "prox-srvarrvm",
  srvarrPorts,
}:
let
  renderService =
    service:
    service
    // (
      if service.scope == "external" then
        {
          probeUrl = "https://${service.publicHost}${service.probePath}";
          url = "https://${service.publicHost}";
        }
      else if service.owner == "fana" then
        {
          probeUrl = "${grafanaProbeUrl}${service.probePath}";
          url = grafanaDisplayUrl;
        }
      else
        {
          probeUrl = "http://${srvarrProbeHost}:${toString srvarrPorts.${service.id}}${service.probePath}";
          url = "http://${srvarrDisplayHost}:${toString srvarrPorts.${service.id}}/";
        }
    );
in
map renderService hostInventory.services
