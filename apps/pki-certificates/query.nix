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
  authority = configuredHost.host.pki.authority;
in
{
  realm = configuredHost.host.realm;
  authority = configuredHost.host.pki.realmAuthority;
  ca_url = if configuredHost.host.pki.role == "authority" then authority.api.url else null;
  identity = {
    dns_name = dnsName;
    networking_name = networkingName;
    avahi_name = avahiName;
  };
  internal_services = configuredHost.host.internalHttps.services or { };
  clients = configuredHost.host.pki.clients or { };
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
  managed_certificates = configuredHost.host.pki.managedCertificates;
}
