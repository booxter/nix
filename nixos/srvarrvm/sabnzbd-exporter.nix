{
  config,
  ...
}:
let
  sabnzbdExporterInternalPort = 19387;
in
{
  sops.templates."sabnzbd-exporter.apikey" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      ${config.sops.placeholder."sabnzbd/apiKey"}
    '';
  };

  services.prometheus.exporters.sabnzbd = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = sabnzbdExporterInternalPort;
    servers = [
      {
        baseUrl = "http://127.0.0.1:${toString config.services.sabnzbd.settings.misc.port}";
        apiKeyFile = config.sops.templates."sabnzbd-exporter.apikey".path;
      }
    ];
  };

  host.observability.client.prometheusMtlsEndpoints.sabnzbd = {
    enable = true;
    port = 9387;
    upstream = "http://127.0.0.1:${toString sabnzbdExporterInternalPort}/metrics";
  };
}
