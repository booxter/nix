{
  configuration,
  host,
  repo,
}:
let
  flake = builtins.getFlake "path:${repo}";
  configuredHost = (builtins.getAttr host (builtins.getAttr configuration flake)).config;
  dnsName = configuredHost.networking.hostName;
  networkingName = dnsName;
  avahiName = configuredHost.services.avahi.hostName or dnsName;
  nodeExporterEnabled = configuredHost.host.observability.nodeExporter.mtls.enable or false;
in
{
  identity = {
    dns_name = dnsName;
    networking_name = networkingName;
    avahi_name = avahiName;
  };
  internal_services = configuredHost.host.internalHttps.services or { };
  clients = configuredHost.host.internalPki.clients or { };
  proxmox_api =
    if configuredHost.host.proxmox.apiCertificate.enable or false then
      configuredHost.host.proxmox.apiCertificate
    else
      null;
  observability_endpoints = configuredHost.host.observability.prometheusEndpoints or { };
  node_exporter =
    if nodeExporterEnabled then
      {
        enable = true;
        port = configuredHost.services.prometheus.exporters.node.port;
        sans =
          configuredHost.host.observability.prometheusEndpointSans or [
            dnsName
            networkingName
            avahiName
            "${avahiName}.local"
          ];
        secretPrefix = configuredHost.host.observability.nodeExporter.mtls.secretPrefix;
      }
    else
      null;
}
