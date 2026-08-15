{
  config,
  lib,
  outputs,
  pkgs,
  utils,
  ...
}:
let
  authority = import ../../../common/_mixins/internal-pki/model.nix { inherit config; };
  enabled = config.host.pki.server != null;
  caPort = authority.port;
  stateDir = "/var/lib/step-ca";
  passwordFile = "${stateDir}/password.txt";
  statusMetricsPath = "${config.host.observability.nodeExporter.textfile.directories.default}/pki-certs.prom";
  rotationMetricsPath = "${config.host.observability.nodeExporter.textfile.directories.default}/pki-rotation.prom";
  bootstrap = pkgs.callPackage ./pkgs/step-ca-bootstrap { };
  configurations = outputs.nixosConfigurations // outputs.darwinConfigurations;
  realmsByHost = lib.mapAttrs (_: configuration: configuration.config.host.realm) configurations;
  sopsTools = import ../../../apps/sops/package.nix { inherit pkgs realmsByHost; };
  pkiCertificates = pkgs.callPackage ../../../apps/pki-certificates {
    atomicFileWrites = pkgs.atomic-file-writes;
    inherit sopsTools;
  };
  pkiRotation = pkgs.callPackage ../../../pkgs/pki-rotation {
    atomicFileWrites = pkgs.atomic-file-writes;
    gitCommandRunner = pkgs.git-command-runner;
    inherit pkiCertificates sopsTools;
  };
  inventory =
    let
      taggedConfigurations =
        lib.mapAttrs (_: value: {
          configuration = "nixosConfigurations";
          inherit value;
        }) outputs.nixosConfigurations
        // lib.mapAttrs (_: value: {
          configuration = "darwinConfigurations";
          inherit value;
        }) outputs.darwinConfigurations;
      value = import ../../../common/_mixins/internal-pki/inventory.nix {
        configurations = taggedConfigurations;
        inherit lib;
        repoRoot = ../../..;
      };
    in
    builtins.toFile "pki-certificate-inventory.json" (builtins.toJSON value);
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
    inherit (authority) certificateLifetime;
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
          Environment = [ "HOME=/root" ];
          ExecStart = utils.escapeSystemdExecArgs [
            (lib.getExe pkiRotation)
            "rotate"
            "--github-token-file"
            config.sops.secrets.pkiRotationGithubToken.path
            "--metrics-output"
            rotationMetricsPath
          ];
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
