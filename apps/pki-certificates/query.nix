{
  configuration,
  host,
  repo,
}:
let
  flake = builtins.getFlake "path:${repo}";
  configuredHost = (builtins.getAttr host (builtins.getAttr configuration flake)).config;
  dnsName = configuredHost.host.dnsName;
  networkingName = configuredHost.networking.hostName;
  avahiName = configuredHost.services.avahi.hostName or dnsName;
  nodeExporterEnabled = configuredHost.host.observability.client.nodeExporter.mtls.enable or false;
in
{
  identity = {
    dns_name = dnsName;
    networking_name = networkingName;
    avahi_name = avahiName;
  };
  internal_services = configuredHost.host.internalHttps.services or { };
  internal_clients = configuredHost.host.internalHttps.mtlsClients or { };
  external_clients = configuredHost.host.externalService.mtlsClients or { };
  proxmox_api =
    if configuredHost.host.proxmox.apiCertificate.enable or false then
      configuredHost.host.proxmox.apiCertificate
    else
      null;
  observability_endpoints = configuredHost.host.observability.client.prometheusMtlsEndpoints or { };
  observability_clients = configuredHost.host.observability.client.mtlsClients or { };
  node_exporter =
    if nodeExporterEnabled then
      {
        enable = true;
        port = configuredHost.services.prometheus.exporters.node.port;
        sans =
          configuredHost.host.observability.client.prometheusMtlsServerSans or [
            dnsName
            networkingName
            avahiName
            "${avahiName}.local"
          ];
        secretPrefix = "prometheus/node_exporter";
      }
    else
      null;
}
