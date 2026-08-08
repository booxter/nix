{
  config,
  lib,
  ...
}:
let
  cfg = config.services.sabnzbd;
  sabnzbdExporterInternalPort = 19387;
in
{
  config = lib.mkIf cfg.exporter.enable {
    sops.templates."sabnzbd-exporter.apikey" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "prometheus-sabnzbd-exporter.service" ];
      content = ''
        ${config.sops.placeholder."sabnzbd/apiKey"}
      '';
    };

    systemd.services.prometheus-sabnzbd-exporter = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
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

    host.observability.metricsEndpoints.sabnzbd = {
      enable = true;
      port = 9387;
      upstream = "http://127.0.0.1:${toString sabnzbdExporterInternalPort}/metrics";
      scrape = {
        enable = true;
        service = "sabnzbd";
      };
    };
  };
}
