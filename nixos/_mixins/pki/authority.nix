{
  config,
  hostSpec,
  lib,
  outputs,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.pki.authority;
  enabled = config.host.pki.role == "authority";
  certLifetime = "${toString (cfg.leafLifetimeDays * 24)}h0m0s";
  caPort = cfg.api.port;
  stateDir = "/var/lib/step-ca";
  passwordFile = "${stateDir}/password.txt";
  statusMetricsPath = "/var/lib/prometheus-node-exporter-textfile/pki-certs.prom";
  rotationMetricsPath = "/var/lib/prometheus-node-exporter-textfile/pki-rotation.prom";
  bootstrap = pkgs.callPackage ./pkgs/step-ca-bootstrap { };
  inventory = import ../../pki/inventory.nix {
    inherit config lib outputs;
  };
  dnsNames = lib.unique (
    hostSpec.certificateDnsNames
    ++ [
      config.networking.hostName
      config.services.avahi.hostName
      "${config.services.avahi.hostName}.local"
    ]
  );
  bootstrapConfig = (pkgs.formats.json { }).generate "step-ca-bootstrap.json" {
    stateDirectory = stateDir;
    name = cfg.displayName;
    url = cfg.api.url;
    inherit dnsNames;
    address = ":${toString caPort}";
    provisioner = cfg.provisioner;
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
  options.host.pki.authority = {
    rotation = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to rotate due realm leaf certificates through review PRs.";
      };
      windowDays = lib.mkOption {
        type = lib.types.ints.positive;
        default = 45;
        description = "Remaining lifetime at which a leaf certificate becomes due for rotation.";
      };
      baseBranch = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "master";
        description = "Repository branch targeted by certificate rotation PRs.";
      };
      githubTokenSopsKey = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "github/pki_rotation/token";
        description = "SOPS key containing the GitHub token used by the rotation controller.";
      };
    };
  };

  config = lib.mkIf enabled {
    host.dashboard.entries.pki-root-ca = {
      enable = true;
      title = "PKI Root CA";
      icon = "sh:smallstep";
      section = "infrastructure";
      endpoints.internal = {
        url = "${cfg.api.url}${cfg.api.rootsPath}";
        checkUrl = "${cfg.api.url}${cfg.api.rootsPath}";
      };
    };

    host.backups.sources.step-ca.paths = [ stateDir ];

    host.observability = {
      enable = true;
      nodeExporter.mtls.enable = true;
    };

    networking.firewall.allowedTCPPorts = [ caPort ];

    environment.systemPackages = with pkgs; [
      pki-rotation
      step-ca
      step-cli
    ];

    users.users.step-ca = {
      isSystemUser = true;
      group = "step-ca";
      home = stateDir;
      createHome = false;
    };
    users.groups.step-ca = { };

    sops.secrets.pkiRotationGithubToken = lib.mkIf cfg.rotation.enable {
      key = cfg.rotation.githubTokenSopsKey;
      mode = "0400";
      restartUnits = [ "pki-rotate.service" ];
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/prometheus-node-exporter-textfile 0755 root root - -"
    ];

    systemd.services = {
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

      pki-status-export = {
        description = "Export internal PKI status metrics for node exporter";
        wants = [ "step-ca.service" ];
        after = [ "step-ca.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = ''
            ${pkgs.pki-rotation}/bin/pki-rotation \
              --intermediate-cert-path ${stateDir}/certs/intermediate_ca.crt \
              export-metrics \
              --inventory-manifest ${inventory} \
              --output ${statusMetricsPath}
          '';
        };
      };

      pki-rotate = lib.mkIf cfg.rotation.enable {
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
              --rotation-window-days ${toString cfg.rotation.windowDays} \
              --intermediate-cert-path ${stateDir}/certs/intermediate_ca.crt \
              --sops-age-key-file /var/lib/sops-nix/key.txt \
              rotate \
              --base-branch ${lib.escapeShellArg cfg.rotation.baseBranch} \
              --github-token-file ${config.sops.secrets.pkiRotationGithubToken.path} \
              --metrics-output ${rotationMetricsPath}
          '';
        };
      };
    };

    systemd.timers = {
      pki-status-export = {
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

      pki-rotate = lib.mkIf cfg.rotation.enable {
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
