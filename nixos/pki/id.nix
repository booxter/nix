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
  lan = hostInventory.site.lan;
  sso = hostInventory.sso;
  kanidmPort = 18085;
  kanidmLocalHost = idService.id;
  kanidmLocalUrl = "https://${kanidmLocalHost}:${toString kanidmPort}";
  grafanaUrl = "https://grafana.${lan.domain}";
  vikunjaService = hostInventory.servicesById.vikunja;
  vikunjaUrl = "https://${vikunjaService.publicHost}";
  openWebuiService = hostInventory.servicesById.ai;
  openWebuiUrl = "https://${openWebuiService.publicHost}";
  paperlessService = hostInventory.servicesById.paperless;
  paperlessUrl = "https://${paperlessService.publicHost}";
  rommService = hostInventory.servicesById.romm;
  rommUrl = "https://${rommService.publicHost}";
  aurralService = hostInventory.servicesById.aurral;
  aurralUrl = "https://${aurralService.publicHost}";
  shelfmarkService = hostInventory.servicesById.shelfmark;
  shelfmarkUrl = "https://${shelfmarkService.publicHost}";
  srvarrAdminAppsUrl = "https://bazarr.${lan.domain}";
  srvarrAdminAppHosts = lib.unique (
    lib.concatMap hostInventory.toInternalHttpsServiceHosts hostInventory.srvarrAdminAppIds
  );
  srvarrAdminAppOriginUrls = map (host: "https://${host}/oauth2/callback") srvarrAdminAppHosts;
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
    kanidmGrafanaOAuthClientSecret = {
      key = "kanidm/oauth2/grafana/client_secret";
      owner = "kanidm";
      group = "kanidm";
      mode = "0400";
      restartUnits = [ "kanidm.service" ];
    };
    kanidmVikunjaOAuthClientSecret = {
      key = "kanidm/oauth2/vikunja/client_secret";
      owner = "kanidm";
      group = "kanidm";
      mode = "0400";
      restartUnits = [ "kanidm.service" ];
    };
    kanidmOpenWebuiOAuthClientSecret = {
      key = "kanidm/oauth2/open-webui/client_secret";
      owner = "kanidm";
      group = "kanidm";
      mode = "0400";
      restartUnits = [ "kanidm.service" ];
    };
    kanidmPaperlessOAuthClientSecret = {
      key = "kanidm/oauth2/paperless/client_secret";
      owner = "kanidm";
      group = "kanidm";
      mode = "0400";
      restartUnits = [ "kanidm.service" ];
    };
    kanidmRommOAuthClientSecret = {
      key = "kanidm/oauth2/romm/client_secret";
      owner = "kanidm";
      group = "kanidm";
      mode = "0400";
      restartUnits = [ "kanidm.service" ];
    };
    kanidmAurralOAuthClientSecret = {
      key = "kanidm/oauth2/aurral/client_secret";
      owner = "kanidm";
      group = "kanidm";
      mode = "0400";
      restartUnits = [ "kanidm.service" ];
    };
    kanidmShelfmarkOAuthClientSecret = {
      key = "kanidm/oauth2/shelfmark/client_secret";
      owner = "kanidm";
      group = "kanidm";
      mode = "0400";
      restartUnits = [ "kanidm.service" ];
    };
    kanidmSrvarrAdminAppsOAuthClientSecret = {
      key = "kanidm/oauth2/srvarr-admin-apps/client_secret";
      owner = "kanidm";
      group = "kanidm";
      mode = "0400";
      restartUnits = [ "kanidm.service" ];
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
      systems.oauth2.grafana = {
        displayName = "Grafana";
        originUrl = "${grafanaUrl}/login/generic_oauth";
        originLanding = "${grafanaUrl}/";
        basicSecretFile = config.sops.secrets.kanidmGrafanaOAuthClientSecret.path;
        preferShortUsername = true;
        scopeMaps = {
          "grafana-admins" = [
            "openid"
            "email"
            "profile"
          ];
          "grafana-viewers" = [
            "openid"
            "email"
            "profile"
          ];
        };
        claimMaps.grafana_role.valuesByGroup = {
          "grafana-admins" = [ "admin" ];
          "grafana-viewers" = [ "viewer" ];
        };
      };
      systems.oauth2.vikunja = {
        displayName = "Vikunja";
        originUrl = "${vikunjaUrl}/auth/openid/sso";
        originLanding = "${vikunjaUrl}/";
        basicSecretFile = config.sops.secrets.kanidmVikunjaOAuthClientSecret.path;
        allowInsecureClientDisablePkce = true;
        preferShortUsername = true;
        scopeMaps."vikunja-users" = [
          "openid"
          "email"
          "profile"
        ];
      };
      systems.oauth2.open-webui = {
        displayName = "Open WebUI";
        originUrl = "${openWebuiUrl}/oauth/oidc/login/callback";
        originLanding = "${openWebuiUrl}/";
        basicSecretFile = config.sops.secrets.kanidmOpenWebuiOAuthClientSecret.path;
        preferShortUsername = true;
        scopeMaps."ai-users" = [
          "openid"
          "email"
          "profile"
        ];
        claimMaps.open_webui_role.valuesByGroup = {
          "ai-users" = [ "user" ];
          "sso-admins" = [ "admin" ];
        };
      };
      systems.oauth2.paperless = {
        displayName = "Paperless";
        originUrl = "${paperlessUrl}/accounts/oidc/sso/login/callback/";
        originLanding = "${paperlessUrl}/";
        basicSecretFile = config.sops.secrets.kanidmPaperlessOAuthClientSecret.path;
        preferShortUsername = true;
        scopeMaps = {
          "paperless-admins" = [
            "openid"
            "email"
            "profile"
            "groups"
          ];
          "paperless-users" = [
            "openid"
            "email"
            "profile"
            "groups"
          ];
        };
        claimMaps.groups.valuesByGroup = {
          "paperless-admins" = [ "paperless-admins" ];
          "paperless-users" = [ "paperless-users" ];
        };
      };
      systems.oauth2.romm = {
        displayName = "RomM";
        originUrl = "${rommUrl}/api/oauth/openid";
        originLanding = "${rommUrl}/";
        basicSecretFile = config.sops.secrets.kanidmRommOAuthClientSecret.path;
        allowInsecureClientDisablePkce = true;
        preferShortUsername = true;
        scopeMaps = {
          "romm-admins" = [
            "openid"
            "email"
            "profile"
            "romm_roles"
          ];
          "romm-editors" = [
            "openid"
            "email"
            "profile"
            "romm_roles"
          ];
          "romm-viewers" = [
            "openid"
            "email"
            "profile"
            "romm_roles"
          ];
        };
        claimMaps.romm_roles.valuesByGroup = {
          "romm-admins" = [ "romm-admins" ];
          "romm-editors" = [ "romm-editors" ];
          "romm-viewers" = [ "romm-viewers" ];
        };
      };
      systems.oauth2.aurral = {
        displayName = "Aurral";
        originUrl = "${aurralUrl}/oauth2/callback";
        originLanding = "${aurralUrl}/";
        basicSecretFile = config.sops.secrets.kanidmAurralOAuthClientSecret.path;
        preferShortUsername = true;
        scopeMaps = {
          "media-admins" = [
            "openid"
            "email"
            "profile"
            "media_groups"
          ];
          "media-users" = [
            "openid"
            "email"
            "profile"
            "media_groups"
          ];
        };
        claimMaps.media_groups.valuesByGroup = {
          "media-admins" = [ "media-admins" ];
          "media-users" = [ "media-users" ];
        };
      };
      systems.oauth2.shelfmark = {
        displayName = "Shelfmark";
        originUrl = "${shelfmarkUrl}/api/auth/oidc/callback";
        originLanding = "${shelfmarkUrl}/";
        basicSecretFile = config.sops.secrets.kanidmShelfmarkOAuthClientSecret.path;
        preferShortUsername = true;
        scopeMaps = {
          "media-admins" = [
            "openid"
            "email"
            "profile"
            "media_groups"
          ];
          "media-users" = [
            "openid"
            "email"
            "profile"
            "media_groups"
          ];
        };
        claimMaps.media_groups.valuesByGroup = {
          "media-admins" = [ "media-admins" ];
          "media-users" = [ "media-users" ];
        };
      };
      systems.oauth2.srvarr-admin-apps = {
        displayName = "srvarr admin apps";
        originUrl = srvarrAdminAppOriginUrls;
        originLanding = "${srvarrAdminAppsUrl}/";
        basicSecretFile = config.sops.secrets.kanidmSrvarrAdminAppsOAuthClientSecret.path;
        preferShortUsername = true;
        scopeMaps."infra-admins" = [
          "openid"
          "email"
          "profile"
          "infra_groups"
        ];
        claimMaps.infra_groups.valuesByGroup."infra-admins" = [ "infra-admins" ];
      };
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
