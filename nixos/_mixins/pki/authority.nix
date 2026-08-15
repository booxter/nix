{
  config,
  lib,
  outputs,
  pkgs,
  utils,
  ...
}:
let
  authority = config.host.pki.authority;
  enabled = config.host.pki.server != null;
  certLifetime = "${toString (authority.leafLifetimeDays * 24)}h0m0s";
  caPort = authority.port;
  stateDir = "/var/lib/step-ca";
  passwordFile = "${stateDir}/password.txt";
  statusMetricsPath = "${config.host.observability.nodeExporter.textfile.directories.default}/pki-certs.prom";
  rotationMetricsPath = "/var/lib/prometheus-node-exporter-textfile/pki-rotation.prom";
  bootstrap = pkgs.callPackage ./pkgs/step-ca-bootstrap { };
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  realmsByHost = lib.mapAttrs (_: configuration: configuration.config.host.realm) configurations;
  appPackages = import ../../../apps/packages.nix { inherit pkgs realmsByHost; };
  pkiRotation = pkgs.callPackage ../../../pkgs/pki-rotation {
    atomicFileWrites = pkgs.atomic-file-writes;
    gitCommandRunner = pkgs.git-command-runner;
    pkiCertificates = appPackages.issue-internal-service-cert;
    sopsTools = appPackages.sops-tools;
  };
  inventory = import ../../pki/inventory.nix {
    inherit config lib outputs;
  };
  dnsNames = lib.unique (
    config.host.network.certificateDnsNames
    ++ [
      config.networking.hostName
      config.services.avahi.hostName
      "${config.services.avahi.hostName}.local"
    ]
  );
  bootstrapConfig = (pkgs.formats.json { }).generate "step-ca-bootstrap.json" {
    stateDirectory = stateDir;
    name = authority.displayName;
    url = authority.url;
    inherit dnsNames;
    address = ":${toString caPort}";
    provisioner = authority.provisioner;
    certificateLifetime = certLifetime;
  };
  bootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe bootstrap)
    "--config"
    bootstrapConfig
    "--step"
    (lib.getExe pkgs.step-cli)
  ];
in
{
  config = {
    assertions = [
      {
        assertion = !enabled || authority != null;
        message = "host.pki.server requires a realm PKI authority";
      }
      {
        assertion = !enabled || authority.hostName == config.networking.hostName;
        message = "host.pki.server must run on the realm PKI authority host";
      }
    ];

    host.backups.sources.step-ca.paths = lib.mkIf enabled [ stateDir ];

    host.dashboard.entries.pki-root-ca = lib.mkIf enabled {
      title = "PKI Root CA";
      icon = "sh:smallstep";
      section = "infrastructure";
      url = "${authority.url}${authority.rootsPath}";
    };

    host.observability = lib.mkIf enabled {
      nodeExporter.textfile.periodicProducers.pki-status-export = {
        description = "Export internal PKI status metrics for node exporter";
        command = [
          (lib.getExe pkiRotation)
          "--intermediate-cert-path"
          "${stateDir}/certs/intermediate_ca.crt"
          "export-metrics"
          "--inventory-manifest"
          inventory
          "--output"
          statusMetricsPath
        ];
        wants = [ "step-ca.service" ];
        after = [ "step-ca.service" ];
        onBootSec = "5m";
        interval = "1h";
        randomizedDelaySec = "5m";
        persistent = true;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf enabled [ caPort ];

    environment.systemPackages = lib.mkIf enabled [
      pkiRotation
      pkgs.step-ca
      pkgs.step-cli
    ];

    users.users.step-ca = lib.mkIf enabled {
      isSystemUser = true;
      group = "step-ca";
      home = stateDir;
      createHome = false;
    };
    users.groups.step-ca = lib.mkIf enabled { };

    sops.secrets.pkiRotationGithubToken = lib.mkIf enabled {
      key = "github/pki_rotation/token";
      mode = "0400";
      restartUnits = [ "pki-rotate.service" ];
    };

    systemd.tmpfiles.rules = lib.mkIf enabled [
      "d /var/lib/prometheus-node-exporter-textfile 0755 root root - -"
    ];

    systemd.services = lib.mkIf enabled {
      step-ca = {
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
          WorkingDirectory = stateDir;
          Environment = [
            "HOME=${stateDir}"
            "STEPPATH=${stateDir}"
          ];
          ExecStartPre = bootstrapCommand;
          ExecStart = "${pkgs.step-ca}/bin/step-ca ${stateDir}/config/ca.json --password-file ${passwordFile}";
          Restart = "on-failure";
          RestartSec = "5s";
          NoNewPrivileges = true;
          PrivateTmp = true;
        };
      };

      pki-rotate = {
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
            ${pkiRotation}/bin/pki-rotation \
              --rotation-window-days 45 \
              --intermediate-cert-path ${stateDir}/certs/intermediate_ca.crt \
              --sops-age-key-file /var/lib/sops-nix/key.txt \
              rotate \
              --base-branch master \
              --github-token-file ${config.sops.secrets.pkiRotationGithubToken.path} \
              --metrics-output ${rotationMetricsPath}
          '';
        };
      };
    };

    systemd.timers = lib.mkIf enabled {
      pki-rotate = {
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
  };
}
