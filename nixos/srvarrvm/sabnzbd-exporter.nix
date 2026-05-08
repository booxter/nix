{
  config,
  pkgs,
  ...
}:
let
  sabnzbdApiKeyFile = "/run/prometheus-sabnzbd-exporter/apikey";
in
{
  services.prometheus.exporters.sabnzbd = {
    enable = true;
    openFirewall = true;
    servers = [
      {
        baseUrl = "http://127.0.0.1:${toString config.nixarr.sabnzbd.guiPort}";
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
      sed -n 's/^api_key = //p' ${config.nixarr.sabnzbd.stateDir}/sabnzbd.ini > ${sabnzbdApiKeyFile}
      test -s ${sabnzbdApiKeyFile}
    '';
  };
}
