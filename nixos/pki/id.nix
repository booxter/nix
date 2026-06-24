{
  config,
  hostInventory,
  lib,
  pkiPkgs,
  pkgs,
  ...
}:
let
  idService = hostInventory.servicesById.id;
  sso = hostInventory.sso;
  kanidmPort = 18085;
  kanidmLocalHost = idService.id;
  kanidmLocalUrl = "https://${kanidmLocalHost}:${toString kanidmPort}";
  mailSenderUser = "kanidm-mail-sender";
  mailSenderGroup = mailSenderUser;
  mailSenderStateDir = "/var/lib/kanidm-mail-sender";
  mailSenderTokenFile = "${mailSenderStateDir}/token";
  mailSenderRuntimeDir = "/run/kanidm-mail-sender";
  mailSenderConfigFile = "${mailSenderRuntimeDir}/mail-sender.toml";
  kanidmProvisionGroups = lib.mapAttrs (_: _: { }) sso.groups;
  kanidmProvisionPersons = lib.mapAttrs (
    _: person:
    {
      displayName = person.displayName;
      groups = person.groups;
    }
    // lib.optionalAttrs (person ? legalName) { inherit (person) legalName; }
    // lib.optionalAttrs (person ? mailAddresses) { inherit (person) mailAddresses; }
  ) sso.users;
  writeMailSenderConfig = pkgs.writeShellApplication {
    name = "kanidm-mail-sender-write-config";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      set -euo pipefail

      token_file=${lib.escapeShellArg mailSenderTokenFile}
      password_file=${lib.escapeShellArg config.sops.secrets.kanidmMailerPassword.path}
      config_file=${lib.escapeShellArg mailSenderConfigFile}
      tmp_config="$(mktemp)"
      trap 'rm -f "$tmp_config"' EXIT

      [ -s "$token_file" ]
      [ -r "$password_file" ]

      token="$(jq -Rs 'sub("\n$"; "")' < "$token_file")"
      password="$(jq -Rs 'sub("\n$"; "")' < "$password_file")"

      umask 077
      printf '%s\n' \
        "token = $token" \
        'schedule = "*/30 * * * * * *"' \
        'instance_display_name = "SSO"' \
        'instance_url = "https://${idService.publicHost}"' \
        'mail_from_address = "ihar.hrachyshka@gmail.com"' \
        'mail_reply_to_address = "ihar.hrachyshka@gmail.com"' \
        'mail_relay = "smtp.gmail.com"' \
        'mail_username = "ihar.hrachyshka@gmail.com"' \
        "mail_password = $password" \
        'mail_connect_timeout_seconds = 15' \
        > "$tmp_config"
      install -m 0440 -o root -g ${lib.escapeShellArg mailSenderGroup} "$tmp_config" "$config_file"
    '';
  };
in
{
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
      groups = kanidmProvisionGroups;
      persons = kanidmProvisionPersons;
    };
  };

  host.internalHttps.services.id = {
    enable = true;
    upstream = "https://127.0.0.1:${toString kanidmPort}";
    serverAliases = [ idService.publicHost ];
    mtls.enable = true;
    locationExtraConfig = ''
      proxy_set_header Host ${idService.publicHost};
      proxy_set_header X-Forwarded-Host ${idService.publicHost};
    '';
  };

  environment.systemPackages = [ config.services.kanidm.package ];

  networking.hosts."127.0.0.1" = [ kanidmLocalHost ];

  users.users.${mailSenderUser} = {
    isSystemUser = true;
    group = mailSenderGroup;
    home = mailSenderStateDir;
    createHome = false;
  };

  users.groups.${mailSenderGroup} = { };

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
      ExecStart = "${lib.getExe pkiPkgs.kanidm-mail-sender-bootstrap} ${
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
      writeMailSenderConfig
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
      ExecStartPre = "+${lib.getExe writeMailSenderConfig}";
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
}
