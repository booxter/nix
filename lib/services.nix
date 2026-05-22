{
  hostInventory,
  grafanaDisplayUrl ? null,
  grafanaProbeUrl ? "http://127.0.0.1:3000/",
  srvarrDisplayHost ? null,
  srvarrProbeHost ? null,
  srvarrPorts,
}:
let
  ownerSpec = owner: hostInventory.nixosHostSpecsByName.${owner};
  ownerDisplayHost = owner: "${(ownerSpec owner).name}.local";
  ownerProbeHost =
    owner:
    let
      spec = ownerSpec owner;
      proxVmHost = "prox-${hostInventory.toVmName spec.name}";
    in
    spec.dnsName or (spec.dhcpReservation.hostname or proxVmHost);
  grafanaDisplayUrl' = if grafanaDisplayUrl != null then grafanaDisplayUrl else "http://${ownerDisplayHost "fana"}:3000/";
  srvarrDisplayHost' = if srvarrDisplayHost != null then srvarrDisplayHost else ownerDisplayHost "srvarr";
  srvarrProbeHost' = if srvarrProbeHost != null then srvarrProbeHost else ownerProbeHost "srvarr";
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
          url = grafanaDisplayUrl';
        }
      else
        {
          probeUrl = "http://${srvarrProbeHost'}:${toString srvarrPorts.${service.id}}${service.probePath}";
          url = "http://${srvarrDisplayHost'}:${toString srvarrPorts.${service.id}}/";
        }
    );
in
map renderService hostInventory.services
