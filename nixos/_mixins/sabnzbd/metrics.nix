{
  config,
  lib,
  sabnzbdModel,
  ...
}:
let
  cfg = config.host.sabnzbd;
  exporterPort = 19387;
in
{
  config = lib.mkIf (cfg != null) {
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
      port = exporterPort;
      servers = [
        {
          baseUrl = "http://127.0.0.1:${toString sabnzbdModel.port}";
          apiKeyFile = config.sops.templates."sabnzbd-exporter.apikey".path;
        }
      ];
    };

    host.web.services.sabnzbd.metrics.default = {
      port = 9387;
      upstream = "http://127.0.0.1:${toString exporterPort}/metrics";
    };
  };
}
