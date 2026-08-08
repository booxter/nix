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
  outboundMail = hostInventory.realms.${config.host.realm}.services.outboundMail or null;
  providerHost = cfg.host;
  idService = hostInventory.servicesById.id;
  kanidmTools = pkgs.callPackage ./packages/kanidm-tools {
    defaultTarget = providerHost;
  };
  kanidmPort = 18085;
  kanidmLocalHost = idService.id;
  kanidmLocalUrl = "https://${kanidmLocalHost}:${toString kanidmPort}";
  mailSenderUser = "kanidm-mail-sender";
  mailSenderGroup = mailSenderUser;
  mailSenderStateDir = "/var/lib/kanidm-mail-sender";
  mailSenderTokenFile = "${mailSenderStateDir}/token";
  mailSenderRuntimeDir = "/run/kanidm-mail-sender";
  mailSenderConfigFile = "${mailSenderRuntimeDir}/mail-sender.toml";
  kanidmBackupDir = "/var/lib/kanidm/backups";
  mailSenderTemplate = (pkgs.formats.json { }).generate "kanidm-mail-sender-template.json" {
    schedule = "*/30 * * * * * *";
    instanceDisplayName = "SSO";
    instanceUrl = "https://${idService.publicHost}";
    mailFromAddress = outboundMail.fromAddress;
    mailReplyToAddress = outboundMail.replyToAddress;
    mailRelay = outboundMail.host;
    mailUsername = outboundMail.username;
    mailConnectTimeoutSeconds = 15;
  };
  writeMailSenderConfigCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' kanidmTools "kanidm-mail-sender-write-config")
    "--template"
    mailSenderTemplate
    "--token-file"
    mailSenderTokenFile
    "--password-file"
    config.sops.secrets.kanidmMailerPassword.path
    "--output"
    mailSenderConfigFile
    "--output-group"
    mailSenderGroup
  ];
in
{
  imports = [
    ./identities.nix
    ./oidc.nix
  ];

  config = lib.mkIf cfg.enable {
    sops.secrets = {
      kanidmAdminPassword = {
        key = "kanidm/admin_password";
        owner = "kanidm";
        group = "kanidm";
        mode = "0400";
        restartUnits = [ "kanidm.service" ];
      };
      kanidmIdmAdminPassword = {
        key = "kanidm/idm_admin_password";
        owner = "kanidm";
        group = "kanidm";
        mode = "0400";
        restartUnits = [ "kanidm.service" ];
      };
      kanidmServerCrt = {
        key = "kanidm/tls/server_crt_unencrypted";
        owner = "kanidm";
        group = "kanidm";
        mode = "0400";
        restartUnits = [ "kanidm.service" ];
      };
      kanidmServerKey = {
        key = "kanidm/tls/server_key";
        owner = "kanidm";
        group = "kanidm";
        mode = "0400";
        restartUnits = [ "kanidm.service" ];
      };
      kanidmMailerPassword = {
        key = "kanidm/mailer/password";
        owner = mailSenderUser;
        group = mailSenderGroup;
        mode = "0400";
        restartUnits = [ "kanidm-mail-sender.service" ];
      };
    };

    services.kanidm = {
      package = pkgs.kanidmWithSecretProvisioning_1_10;
      server = {
        enable = true;
        settings = {
          adminbindpath = "/run/kanidmd/kanidm.socket";
          bindaddress = "127.0.0.1:${toString kanidmPort}";
          domain = idService.publicHost;
          origin = "https://${idService.publicHost}";
          tls_chain = config.sops.secrets.kanidmServerCrt.path;
          tls_key = config.sops.secrets.kanidmServerKey.path;
          online_backup = {
            schedule = "15 03 * * *";
            versions = 14;
          };
        };
      };
      client.settings.uri = kanidmLocalUrl;
      provision = {
        enable = true;
        adminPasswordFile = config.sops.secrets.kanidmAdminPassword.path;
        idmAdminPasswordFile = config.sops.secrets.kanidmIdmAdminPassword.path;
        instanceUrl = "https://localhost:${toString kanidmPort}";
      };
    };

    host.internalHttps.services.id = {
      enable = true;
      upstream = "https://127.0.0.1:${toString kanidmPort}";
      publicAliases = [ idService.publicHost ];
      mtls.enable = true;
      locationExtraConfig = ''
        proxy_set_header Host ${idService.publicHost};
        proxy_set_header X-Forwarded-Host ${idService.publicHost};
      '';
    };

    environment.systemPackages = [
      config.services.kanidm.package
      kanidmTools
    ];

    networking.hosts."127.0.0.1" = [ kanidmLocalHost ];

    users.users.${mailSenderUser} = {
      isSystemUser = true;
      group = mailSenderGroup;
      home = mailSenderStateDir;
      createHome = false;
    };

    users.groups.${mailSenderGroup} = { };

    systemd.tmpfiles.rules = [
      "d ${kanidmBackupDir} 0700 kanidm kanidm - -"
    ];

    host.backups.jobs.${hostInventory.backups.server.host}.paths = lib.mkBefore [ kanidmBackupDir ];

    systemd.services.kanidm = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };

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
        ExecStart = "${lib.getExe' kanidmTools "kanidm-mail-sender-bootstrap"} ${
          lib.escapeShellArgs [
            "--url"
            kanidmLocalUrl
            "--idm-admin-password-file"
            config.sops.secrets.kanidmIdmAdminPassword.path
            "--token-file"
            mailSenderTokenFile
            "--token-owner"
            mailSenderUser
            "--token-group"
            mailSenderGroup
          ]
        }";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ mailSenderStateDir ];
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
        mailSenderTemplate
        kanidmTools
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
        User = mailSenderUser;
        Group = mailSenderGroup;
        UMask = "0077";
        RuntimeDirectory = "kanidm-mail-sender";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "kanidm-mail-sender";
        StateDirectoryMode = "0700";
        ExecStartPre = "+${writeMailSenderConfigCommand}";
        ExecStart = "${config.services.kanidm.package}/bin/kanidm-mail-sender -c /etc/kanidm/config -m ${mailSenderConfigFile}";
        Restart = "on-failure";
        RestartSec = "10s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          mailSenderRuntimeDir
          mailSenderStateDir
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
