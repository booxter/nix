{
  config,
  hostInventory,
  lib,
  pkiPkgs,
  utils,
  ...
}:
let
  idService = hostInventory.servicesById.id;
  searchService = hostInventory.servicesById.search;
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };
  probeUser = "oidc-probe-user";
  probeClient = oidc.clients."oidc-synthetic-probe";
  probeRedirectUri = probeClient.originUrl;
  probePasswordSecret = config.sops.secrets.kanidmOidcProbePassword;
  metricsFile = "/var/lib/prometheus-node-exporter-textfile/oidc-synthetic.prom";
  stateDir = "/var/lib/oidc-synthetic-probe";
  stateFile = "${stateDir}/state.json";
  bootstrapCommand = utils.escapeSystemdExecArgs [
    "${config.services.kanidm.package}/bin/kanidmd"
    "scripting"
    "recover-account"
    "-c"
    "/etc/kanidm/server.toml"
    probeUser
    "--from-environment"
  ];
in
{
  sops.secrets.kanidmOidcProbePassword = {
    key = "kanidm/oidc-probe/password";
    owner = "root";
    group = "root";
    mode = "0400";
    restartUnits = [
      "kanidm-oidc-probe-bootstrap.service"
      "kanidm-oidc-synthetic-probe.service"
    ];
  };

  systemd.services.kanidm-oidc-probe-bootstrap = {
    description = "Bootstrap Kanidm OIDC synthetic probe account password";
    after = [
      "kanidm.service"
      "sops-install-secrets.service"
    ];
    requires = [
      "kanidm.service"
      "sops-install-secrets.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Environment = "KANIDM_RECOVER_ACCOUNT_PASSWORD_FILE=${probePasswordSecret.path}";
      ExecStart = bootstrapCommand;
      StandardOutput = "null";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };

  systemd.services.kanidm-oidc-synthetic-probe = {
    description = "Run synthetic OIDC and search proxy probes";
    after = [
      "network-online.target"
      "kanidm-oidc-probe-bootstrap.service"
    ];
    wants = [ "network-online.target" ];
    requires = [ "kanidm-oidc-probe-bootstrap.service" ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "oidc-synthetic-probe";
      StateDirectoryMode = "0750";
      ExecStart = "${lib.getExe pkiPkgs.oidc-synthetic-probe} ${
        lib.escapeShellArgs [
          "--idp-url"
          "https://${idService.publicHost}"
          "--username"
          probeUser
          "--password-file"
          probePasswordSecret.path
          "--client-id"
          probeClient.clientId
          "--redirect-uri"
          probeRedirectUri
          "--searxng-url"
          "${searchService.url}/"
          "--metrics-file"
          metricsFile
          "--state-file"
          stateFile
        ]
      }";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [
        "/var/lib/prometheus-node-exporter-textfile"
        stateDir
      ];
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
    };
  };

  systemd.timers.kanidm-oidc-synthetic-probe = {
    description = "Run synthetic OIDC and search proxy probes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3m";
      OnUnitActiveSec = "5m";
      RandomizedDelaySec = "30s";
      Persistent = true;
      Unit = "kanidm-oidc-synthetic-probe.service";
    };
  };
}
