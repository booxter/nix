{
  config,
  hostSpecName,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  pkiPkgs = import ./pkgs pkgs;
  caServer = hostInventory.nixosHostSpecsByName.pki.caServer;
  hostSpec = hostInventory.nixosHostSpecsByName.${hostSpecName};
  caName = "Home Internal PKI";
  certLifetimeDays = 180;
  certLifetime = "${toString (certLifetimeDays * 24)}h0m0s";
  caPort = caServer.port;
  caUrl = "https://${config.host.dnsName}:${toString caPort}";
  caProvisioner = "bootstrap@home.arpa";
  pkiRotationBaseBranch = "master";
  pkiStatusMetricsPath = "/var/lib/prometheus-node-exporter-textfile/pki-certs.prom";
  pkiRotationMetricsPath = "/var/lib/prometheus-node-exporter-textfile/pki-rotation.prom";
  stepStateDir = "/var/lib/step-ca";
  stepPasswordFile = "${stepStateDir}/password.txt";
  caDnsNames = lib.unique (
    hostInventory.toNixosHostCertificateDnsNames hostSpec
    ++ [
      config.networking.hostName
      config.host.dnsName
      config.services.avahi.hostName
      (hostInventory.toLocalDnsName config.services.avahi.hostName)
    ]
  );
  bootstrapConfig = (pkgs.formats.json { }).generate "step-ca-bootstrap.json" {
    stateDirectory = stepStateDir;
    name = caName;
    url = caUrl;
    dnsNames = caDnsNames;
    address = ":${toString caPort}";
    provisioner = caProvisioner;
    certificateLifetime = certLifetime;
  };
  bootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe pkiPkgs.step-ca-bootstrap)
    "--config"
    bootstrapConfig
    "--step"
    (lib.getExe pkgs.step-cli)
  ];
in
{
  _module.args = { inherit pkiPkgs; };

  imports = [
    ./id.nix
    ./oidc-probes.nix
    ./backup.nix
    ./unifi-sync.nix
    ./uptimerobot-sync.nix
    ./wg-home-dns-sync.nix
  ];

  sops.secrets.pkiRotationGithubToken = {
    key = "github/pki_rotation/token";
    mode = "0400";
    restartUnits = [ "pki-rotate.service" ];
  };

  # Run the PKI host behind the standard node-exporter mTLS configuration.
  host.observability.client.enable = true;
  host.observability.client.nodeExporter.mtls.enable = true;

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
      ExecStartPre = bootstrapCommand;
      ExecStart = "${pkgs.step-ca}/bin/step-ca ${stepStateDir}/config/ca.json --password-file ${stepPasswordFile}";
      Restart = "on-failure";
      RestartSec = "5s";
      NoNewPrivileges = true;
      PrivateTmp = true;
    };
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
}
