{
  config,
  lib,
  pkgs,
  ...
}:
let
  hostSecretFile = ../../secrets + "/${config.networking.hostName}.yaml";
  hasHostSecretFile = builtins.pathExists hostSecretFile;
  caName = "Home Internal PKI";
  certLifetime = "${toString (180 * 24)}h0m0s";
  caPort = 8443;
  caProvisioner = "bootstrap@home.arpa";
  pkiStatusMetricsPath = "/var/lib/prometheus-node-exporter-textfile/pki-certs.prom";
  pkiRotationMetricsPath = "/var/lib/prometheus-node-exporter-textfile/pki-rotation.prom";
  stepStateDir = "/var/lib/step-ca";
  stepPasswordFile = "${stepStateDir}/password.txt";
  stepProvisionerPasswordFile = "${stepStateDir}/provisioner-password.txt";
  caDnsNames = [
    config.networking.hostName
    config.host.dnsName
    config.services.avahi.hostName
    "${config.services.avahi.hostName}.local"
  ];
  caDnsArgs = lib.concatMapStringsSep " " (name: "--dns ${lib.escapeShellArg name}") caDnsNames;
  bootstrapScript = pkgs.writeShellScript "step-ca-bootstrap" ''
    set -eu
    umask 077

    if [ ! -s "${stepStateDir}/config/ca.json" ]; then
      if [ ! -s "${stepPasswordFile}" ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 48 > "${stepPasswordFile}"
        chmod 600 "${stepPasswordFile}"
      fi

      if [ ! -s "${stepProvisionerPasswordFile}" ]; then
        ${pkgs.openssl}/bin/openssl rand -base64 48 > "${stepProvisionerPasswordFile}"
        chmod 600 "${stepProvisionerPasswordFile}"
      fi

      ${pkgs.step-cli}/bin/step ca init \
        --deployment-type standalone \
        --name ${lib.escapeShellArg caName} \
        ${caDnsArgs} \
        --address ${lib.escapeShellArg ":${toString caPort}"} \
        --provisioner ${lib.escapeShellArg caProvisioner} \
        --password-file ${lib.escapeShellArg stepPasswordFile} \
        --provisioner-password-file ${lib.escapeShellArg stepProvisionerPasswordFile} \
        --acme
    fi

    tmp_json="$(mktemp)"
    ${pkgs.jq}/bin/jq \
      --arg provisioner ${lib.escapeShellArg caProvisioner} \
      --arg cert_lifetime ${lib.escapeShellArg certLifetime} \
      '
        .authority.provisioners |= map(
          if .name == $provisioner then
            .claims = ((.claims // {}) + {
              defaultTLSCertDuration: $cert_lifetime,
              maxTLSCertDuration: $cert_lifetime
            })
          else
            .
          end
        )
      ' \
      "${stepStateDir}/config/ca.json" > "$tmp_json"
    mv "$tmp_json" "${stepStateDir}/config/ca.json"
  '';
in
{
  imports = [
    ./unifi-sync.nix
  ];

  sops.secrets.pkiRotationGithubToken = {
    key = "github/pki_rotation/token";
    mode = "0400";
    restartUnits = [ "pki-rotate.service" ];
  };

  # Keep the PKI host off observability until its host secret exists, then
  # bring it up behind the standard node-exporter mTLS configuration.
  host.observability.client.enable = hasHostSecretFile;
  host.observability.client.nodeExporter.mtls.enable = hasHostSecretFile;

  networking.firewall.allowedTCPPorts = [ caPort ];

  environment.systemPackages = with pkgs; [
    pki-rotation
    step-ca
    step-cli
  ];

  users.users.step-ca = {
    isSystemUser = true;
    group = "step-ca";
    home = stepStateDir;
    createHome = false;
  };

  users.groups.step-ca = { };

  # TODO: once CA material is managed explicitly instead of bootstrapped on
  # first boot, switch this host to nixpkgs `services.step-ca`.
  systemd.services.step-ca = {
    description = "Smallstep certificate authority";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "notify";
      User = "step-ca";
      Group = "step-ca";
      UMask = "0077";
      StateDirectory = "step-ca";
      WorkingDirectory = stepStateDir;
      Environment = [
        "HOME=${stepStateDir}"
        "STEPPATH=${stepStateDir}"
      ];
      ExecStartPre = bootstrapScript;
      ExecStart = "${pkgs.step-ca}/bin/step-ca ${stepStateDir}/config/ca.json --password-file ${stepPasswordFile}";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
  };

  services.prometheus.exporters.node = {
    enabledCollectors = lib.mkAfter [ "textfile" ];
  };

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
      ExecStart = ''
        ${pkgs.pki-rotation}/bin/pki-rotation \
          --repo-root ${../..} \
          --intermediate-cert-path ${stepStateDir}/certs/intermediate_ca.crt \
          --sops-age-key-file /var/lib/sops-nix/key.txt \
          export-metrics \
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
      ExecStart = ''
        ${pkgs.pki-rotation}/bin/pki-rotation \
          --rotation-window-days 45 \
          --intermediate-cert-path ${stepStateDir}/certs/intermediate_ca.crt \
          --sops-age-key-file /var/lib/sops-nix/key.txt \
          rotate \
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
}
