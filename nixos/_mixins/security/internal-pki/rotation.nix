{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.internalPki.provider;
  pkiRotationBaseBranch = "master";
  pkiStatusMetricsPath = "/var/lib/prometheus-node-exporter-textfile/pki-certs.prom";
  pkiRotationMetricsPath = "/var/lib/prometheus-node-exporter-textfile/pki-rotation.prom";
  stepStateDir = cfg.stateDirectory;
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets.pkiRotationGithubToken = {
      key = "github/pki_rotation/token";
      mode = "0400";
      restartUnits = [ "pki-rotate.service" ];
    };

    environment.systemPackages = [ pkgs.pki-rotation ];

    systemd.tmpfiles.rules = [
      "d /var/lib/prometheus-node-exporter-textfile 0755 root root - -"
    ];

    systemd.services.pki-status-export = {
      description = "Export internal PKI status metrics for node exporter";
      wants = [
        "network-online.target"
        "step-ca.service"
      ];
      after = [
        "network-online.target"
        "step-ca.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "HOME=/root"
          "SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt"
        ];
        ExecStart = ''
          ${pkgs.pki-rotation}/bin/pki-rotation \
            --intermediate-cert-path ${stepStateDir}/certs/intermediate_ca.crt \
            --sops-age-key-file /var/lib/sops-nix/key.txt \
            export-metrics \
            --base-branch ${pkiRotationBaseBranch} \
            --output ${pkiStatusMetricsPath}
        '';
      };
    };

    systemd.timers.pki-status-export = {
      description = "Refresh internal PKI status metrics";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5m";
        OnUnitActiveSec = "1h";
        RandomizedDelaySec = "5m";
        Persistent = true;
        Unit = "pki-status-export.service";
      };
    };

    systemd.services.pki-rotate = {
      description = "Rotate due internal PKI leaf certs and open a review PR";
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
        "step-ca.service"
      ];
      after = [
        "network-online.target"
        "sops-install-secrets.service"
        "step-ca.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "HOME=/root"
          "SOPS_AGE_KEY_FILE=/var/lib/sops-nix/key.txt"
        ];
        ExecStart = ''
          ${pkgs.pki-rotation}/bin/pki-rotation \
            --rotation-window-days 45 \
            --intermediate-cert-path ${stepStateDir}/certs/intermediate_ca.crt \
            --sops-age-key-file /var/lib/sops-nix/key.txt \
            rotate \
            --base-branch ${pkiRotationBaseBranch} \
            --github-token-file ${config.sops.secrets.pkiRotationGithubToken.path} \
            --metrics-output ${pkiRotationMetricsPath}
        '';
      };
    };

    systemd.timers.pki-rotate = {
      description = "Run the internal PKI rotation controller";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "1h";
        Persistent = true;
        Unit = "pki-rotate.service";
      };
    };
  };
}
