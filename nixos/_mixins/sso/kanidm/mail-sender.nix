{
  config,
  hostInventory,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.sso.provider;
  outboundMail = hostInventory.realms.${config.host.realm}.services.outboundMail;
  idService = hostInventory.servicesById.id;
  package = pkgs.callPackage ./packages/kanidm-tools {
    defaultTarget = cfg.host;
  };
  user = "kanidm-mail-sender";
  group = user;
  stateDir = "/var/lib/kanidm-mail-sender";
  tokenFile = "${stateDir}/token";
  runtimeDir = "/run/kanidm-mail-sender";
  configFile = "${runtimeDir}/mail-sender.toml";
  template = (pkgs.formats.json { }).generate "kanidm-mail-sender-template.json" {
    schedule = "*/30 * * * * * *";
    instanceDisplayName = "SSO";
    instanceUrl = "https://${idService.publicHost}";
    mailFromAddress = outboundMail.fromAddress;
    mailReplyToAddress = outboundMail.replyToAddress;
    mailRelay = outboundMail.host;
    mailUsername = outboundMail.username;
    mailConnectTimeoutSeconds = 15;
  };
  writeConfigCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' package "kanidm-mail-sender-write-config")
    "--template"
    template
    "--token-file"
    tokenFile
    "--password-file"
    config.sops.secrets.kanidmMailerPassword.path
    "--output"
    configFile
    "--output-group"
    group
  ];
in
{
  config = lib.mkIf cfg.enable {
    sops.secrets.kanidmMailerPassword = {
      key = "kanidm/mailer/password";
      owner = user;
      inherit group;
      mode = "0400";
      restartUnits = [ "kanidm-mail-sender.service" ];
    };

    users.users.${user} = {
      isSystemUser = true;
      inherit group;
      home = stateDir;
      createHome = false;
    };

    users.groups.${group} = { };

    systemd.services.kanidm-mail-sender-bootstrap = {
      description = "Bootstrap Kanidm mail sender service account";
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
        UMask = "0077";
        StateDirectory = "kanidm-mail-sender";
        StateDirectoryMode = "0700";
        ExecStart = "${lib.getExe' package "kanidm-mail-sender-bootstrap"} ${
          lib.escapeShellArgs [
            "--url"
            config.services.kanidm.client.settings.uri
            "--idm-admin-password-file"
            config.sops.secrets.kanidmIdmAdminPassword.path
            "--token-file"
            tokenFile
            "--token-owner"
            user
            "--token-group"
            group
          ]
        }";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };

    systemd.services.kanidm-mail-sender = {
      description = "Kanidm mail sender";
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [
        config.environment.etc."kanidm/config".source
        template
        package
      ];
      wants = [
        "network-online.target"
        "sops-install-secrets.service"
      ];
      requires = [
        "kanidm.service"
        "kanidm-mail-sender-bootstrap.service"
      ];
      after = [
        "network-online.target"
        "kanidm.service"
        "kanidm-mail-sender-bootstrap.service"
        "sops-install-secrets.service"
      ];
      serviceConfig = {
        User = user;
        Group = group;
        UMask = "0077";
        RuntimeDirectory = "kanidm-mail-sender";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "kanidm-mail-sender";
        StateDirectoryMode = "0700";
        ExecStartPre = "+${writeConfigCommand}";
        ExecStart = "${config.services.kanidm.package}/bin/kanidm-mail-sender -c /etc/kanidm/config -m ${configFile}";
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          runtimeDir
          stateDir
        ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
      environment.RUST_LOG = "kanidm_client=warn,kanidm_mail_sender=info";
    };
  };
}
