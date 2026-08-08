{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  paperlessService = hostInventory.servicesById.paperless;
  isOwner = paperlessService.owner == config.networking.hostName;
  internalPort = 19289;
  mtlsPort = 9348;
  exporter = pkgs.callPackage ./packages/prometheus-paperless-exporter { };
in
{
  config = lib.mkIf isOwner {
    systemd.services.prometheus-paperless-exporter = {
      description = "Prometheus exporter for Paperless-ngx";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "paperless-web.service"
        "sops-install-secrets.service"
      ];
      after = [
        "paperless-web.service"
        "sops-install-secrets.service"
      ];
      environment = {
        PAPERLESS_URL = "http://127.0.0.1:${toString config.services.paperless.port}";
        PAPERLESS_AUTH_TOKEN_FILE = config.sops.secrets."paperless/api/token".path;
      };
      serviceConfig = {
        User = "paperless";
        Group = "paperless";
        ExecStart = "${lib.getExe exporter} --collectors=status,statistics,document --web.disable-exporter-metrics --web.listen-address=127.0.0.1:${toString internalPort}";
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };

    host.observability.prometheusEndpoints.paperless = {
      enable = true;
      port = mtlsPort;
      upstream = "http://127.0.0.1:${toString internalPort}/metrics";
    };
  };
}
