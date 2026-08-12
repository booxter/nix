{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  model = import ./model.nix { inherit config lib outputs; };
  inherit (model) cfg metricsInternalPort;
  packages = import ./packages.nix { inherit pkgs; };
in
{
  config = lib.mkIf cfg.enable {
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
        ExecStart = "${lib.getExe packages.prometheusExporter} --collectors=status,statistics,document --web.disable-exporter-metrics --web.listen-address=127.0.0.1:${toString metricsInternalPort}";
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
      };
    };
  };
}
