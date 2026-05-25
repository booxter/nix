{
  config,
  pkgs,
  ...
}:
let
  sabnzbdExporterInternalPort = 19387;
  sabnzbdApiKeyFile = "/run/prometheus-sabnzbd-exporter/apikey";
in
{
  services.prometheus.exporters.sabnzbd = {
    enable = true;
    listenAddress = "127.0.0.1";
    openFirewall = false;
    port = sabnzbdExporterInternalPort;
    servers = [
      {
        baseUrl = "http://127.0.0.1:${toString config.host.srvarr.services.sabnzbd.port}";
        apiKeyFile = sabnzbdApiKeyFile;
      }
    ];
  };

  systemd.services.prometheus-sabnzbd-exporter-apikey = {
    description = "Extract SABnzbd API key for Prometheus exporter";
    requires = [ "sabnzbd.service" ];
    after = [ "sabnzbd.service" ];
    requiredBy = [ "prometheus-sabnzbd-exporter.service" ];
    before = [ "prometheus-sabnzbd-exporter.service" ];
    path = [
      pkgs.coreutils
      pkgs.gnused
    ];
    serviceConfig.Type = "oneshot";
    script = ''
      install -d -m 0700 /run/prometheus-sabnzbd-exporter
      umask 077
      sed -n 's/^api_key = //p' ${config.host.srvarr.services.sabnzbd.stateDir}/sabnzbd.ini > ${sabnzbdApiKeyFile}
      test -s ${sabnzbdApiKeyFile}
    '';
  };

  host.observability.client.prometheusMtlsEndpoints.sabnzbd = {
    enable = true;
    port = 9387;
    upstream = "http://127.0.0.1:${toString sabnzbdExporterInternalPort}/metrics";
  };
}
