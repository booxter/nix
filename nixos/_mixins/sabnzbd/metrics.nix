{ config, lib, ... }:
let
  cfg = config.host.sabnzbd;
  exporterPort = 19387;
in
{
  config = lib.mkIf (cfg.enable && cfg.metrics.enable) {
    sops.templates."sabnzbd-exporter.apikey" = {
      owner = "root";
      group = "root";
      mode = "0400";
      restartUnits = [ "prometheus-sabnzbd-exporter.service" ];
      content = ''
        ${builtins.getAttr cfg.secrets.apiKey config.sops.placeholder}
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
          baseUrl = "http://127.0.0.1:${toString cfg.port}";
          apiKeyFile = config.sops.templates."sabnzbd-exporter.apikey".path;
        }
      ];
    };

    host.web.services.sabnzbd.metrics.default = {
      enable = true;
      port = 9387;
      upstream = "http://127.0.0.1:${toString exporterPort}/metrics";
    };
  };
}
