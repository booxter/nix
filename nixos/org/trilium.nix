{
  config,
  hostInventory,
  lib,
  orgPkgs,
  pkgs,
  utils,
  ...
}:
let
  oidc = import ../../lib/oidc-clients.nix { inherit lib hostInventory; };
  service = hostInventory.servicesById.notes;
  serviceName = "trilium";
  stateDir = "/var/lib/${serviceName}";
  oidcClientId = "trilium";
  port = 18086;
  bootstrapPort = 18087;
  serviceEnvironment = {
    TRILIUM_DATA_DIR = stateDir;
    TRILIUM_GENERAL_INSTANCENAME = "Trilium Notes";
    TRILIUM_NETWORK_HOST = "127.0.0.1";
    TRILIUM_NETWORK_PORT = toString port;
    TRILIUM_NETWORK_TRUSTEDREVERSEPROXY = "loopback";
    TRILIUM_MULTIFACTORAUTHENTICATION_OAUTHBASEURL = service.url;
    TRILIUM_MULTIFACTORAUTHENTICATION_OAUTHCLIENTID = oidcClientId;
    TRILIUM_MULTIFACTORAUTHENTICATION_OAUTHISSUERBASEURL = oidc.openidBaseUrl oidcClientId;
    TRILIUM_MULTIFACTORAUTHENTICATION_OAUTHISSUERNAME = "SSO";
  };
  bootstrapCommand = utils.escapeSystemdExecArgs [
    (lib.getExe orgPkgs.trilium-bootstrap)
    "--database"
    "${stateDir}/document.db"
    "--base-url"
    "http://127.0.0.1:${toString bootstrapPort}"
    "--password-file"
    config.sops.secrets.trilium-local-password.path
    "--server-command"
    (lib.getExe pkgs.trilium-next-server)
  ];
in
{
  users.groups.${serviceName} = { };

  users.users.${serviceName} = {
    description = "Trilium Notes";
    isSystemUser = true;
    group = serviceName;
    home = stateDir;
  };

  sops.secrets = {
    trilium-local-password = {
      key = "trilium/local_password";
      owner = serviceName;
      group = serviceName;
      mode = "0400";
      restartUnits = [ "trilium-bootstrap.service" ];
    };
    trilium-oidc-client-secret = {
      key = "trilium/oidc/client_secret";
      restartUnits = [
        "trilium-bootstrap.service"
        "${serviceName}.service"
      ];
    };
  };

  sops.templates."trilium-oidc.env" = {
    owner = "root";
    group = "root";
    mode = "0400";
    content = ''
      TRILIUM_MULTIFACTORAUTHENTICATION_OAUTHCLIENTSECRET=${config.sops.placeholder.trilium-oidc-client-secret}
    '';
    restartUnits = [
      "trilium-bootstrap.service"
      "${serviceName}.service"
    ];
  };

  systemd.services = {
    trilium-bootstrap = {
      description = "Bootstrap Trilium Notes with OIDC";
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      after = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      before = [ "${serviceName}.service" ];
      environment = serviceEnvironment // {
        TRILIUM_NETWORK_PORT = toString bootstrapPort;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = serviceName;
        Group = serviceName;
        EnvironmentFile = config.sops.templates."trilium-oidc.env".path;
        StateDirectory = serviceName;
        StateDirectoryMode = "0750";
        WorkingDirectory = stateDir;
        ExecStart = bootstrapCommand;
        TimeoutStartSec = "5min";
        UMask = "0027";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };

    ${serviceName} = {
      description = "Trilium Notes";
      wantedBy = [ "multi-user.target" ];
      requires = [ "trilium-bootstrap.service" ];
      after = [ "trilium-bootstrap.service" ];
      environment = serviceEnvironment;
      serviceConfig = {
        User = serviceName;
        Group = serviceName;
        EnvironmentFile = config.sops.templates."trilium-oidc.env".path;
        StateDirectory = serviceName;
        StateDirectoryMode = "0750";
        WorkingDirectory = stateDir;
        ExecStart = lib.getExe pkgs.trilium-next-server;
        Restart = "on-failure";
        RestartSec = "10s";
        TimeoutStopSec = "20s";
        UMask = "0027";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };
  };

  host.internalHttps.services.notes = {
    enable = true;
    upstream = "http://127.0.0.1:${toString port}";
    publicAliases = [ service.publicHost ];
    mtls.enable = true;
    probe.enable = true;
    locationExtraConfig = ''
      client_max_body_size 0;
      proxy_buffer_size 128k;
      proxy_buffers 4 256k;
      proxy_busy_buffers_size 256k;
      proxy_read_timeout 3600s;
      proxy_send_timeout 3600s;
    '';
  };

  services.nginx.virtualHosts."internal-https-notes-probe".locations."= /api/health-check" = {
    proxyPass = "http://127.0.0.1:${toString port}";
    recommendedProxySettings = true;
    extraConfig = ''
      auth_request off;
    '';
  };
}
