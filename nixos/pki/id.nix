{
  config,
  hostInventory,
  lib,
  outputs,
  pkiPkgs,
  pkgs,
  utils,
  ...
}:
let
  idService = hostInventory.servicesById.id;
  sso = hostInventory.sso;
  oidcClients = import ./oidc-clients.nix {
    inherit lib outputs;
    providerHost = config.networking.hostName;
  };
  kanidmOAuthSecretAttrName = clientId: "kanidm-oauth2-${clientId}-client-secret";
  kanidmOAuthSecretKey = clientId: "kanidm/oauth2/${clientId}/client_secret";
  confidentialOidcClients = lib.filterAttrs (_: client: !client.public) oidcClients;
  referencedOidcGroups = lib.unique (
    lib.concatMap (
      client:
      builtins.attrNames client.scopeMaps
      ++ lib.concatMap (claimMap: builtins.attrNames claimMap.valuesByGroup) (
        builtins.attrValues client.claimMaps
      )
    ) (builtins.attrValues oidcClients)
  );
  unknownOidcGroups = lib.subtractLists (builtins.attrNames sso.groups) referencedOidcGroups;
  kanidmProvisionClients =
    secretPathFor:
    lib.mapAttrs (_: client: {
      inherit (client)
        allowInsecureClientDisablePkce
        claimMaps
        displayName
        enableLocalhostRedirects
        enableLegacyCrypto
        originLanding
        preferShortUsername
        public
        scopeMaps
        ;
      originUrl =
        if builtins.length client.originUrls == 1 then
          builtins.head client.originUrls
        else
          client.originUrls;
      basicSecretFile = if client.public then null else secretPathFor client.clientId;
    }) oidcClients;
  kanidmPort = 18085;
  kanidmLocalHost = idService.id;
  kanidmLocalUrl = "https://${kanidmLocalHost}:${toString kanidmPort}";
  mailSenderUser = "kanidm-mail-sender";
  mailSenderGroup = mailSenderUser;
  mailSenderStateDir = "/var/lib/kanidm-mail-sender";
  mailSenderTokenFile = "${mailSenderStateDir}/token";
  mailSenderRuntimeDir = "/run/kanidm-mail-sender";
  mailSenderConfigFile = "${mailSenderRuntimeDir}/mail-sender.toml";
  personMailUsers = lib.filterAttrs (_: person: person ? mailAddressSopsKey) sso.users;
  personMailSecretName = name: "kanidm-person-mail-address-${name}";
  personMailProvisionService = "kanidm-person-mail-provision";
  personMailProvisionDir = "/run/${personMailProvisionService}";
  personMailProvisionFile = "${personMailProvisionDir}/persons.json";
  kanidmProvisionGroups = lib.mapAttrs (_: _: { }) sso.groups;
  kanidmProvisionPersons = lib.mapAttrs (
    _: person:
    {
      displayName = person.displayName;
      groups = person.groups;
    }
    // lib.optionalAttrs (person ? legalName) { inherit (person) legalName; }
  ) sso.users;
  personMailProvision = pkiPkgs.kanidm-person-mail-provision;
  personMailProvisionArgs = [
    personMailProvisionFile
  ]
  ++ lib.concatMap (name: [
    name
    config.sops.secrets.${personMailSecretName name}.path
  ]) (builtins.attrNames personMailUsers);
  mailSenderTemplate = (pkgs.formats.json { }).generate "kanidm-mail-sender-template.json" {
    schedule = "*/30 * * * * * *";
    instanceDisplayName = "SSO";
    instanceUrl = "https://${idService.publicHost}";
    mailFromAddress = "ihar.hrachyshka@gmail.com";
    mailReplyToAddress = "ihar.hrachyshka@gmail.com";
    mailRelay = "smtp.gmail.com";
    mailUsername = "ihar.hrachyshka@gmail.com";
    mailConnectTimeoutSeconds = 15;
  };
  writeMailSenderConfigCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' pkiPkgs.kanidm-mail-sender-bootstrap "kanidm-mail-sender-write-config")
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
  assertions = [
    {
      assertion = unknownOidcGroups == [ ];
      message = "OIDC registrations reference unknown Kanidm groups: ${lib.concatStringsSep ", " unknownOidcGroups}";
    }
  ];

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
  }
  // lib.mapAttrs' (
    name: person:
    lib.nameValuePair (personMailSecretName name) {
      key = person.mailAddressSopsKey;
      owner = "kanidm";
      group = "kanidm";
      mode = "0400";
      restartUnits = [
        "${personMailProvisionService}.service"
        "kanidm.service"
      ];
    }
  ) personMailUsers
  // lib.mapAttrs' (
    _: client:
    lib.nameValuePair (kanidmOAuthSecretAttrName client.clientId) {
      key = kanidmOAuthSecretKey client.clientId;
      owner = "kanidm";
      group = "kanidm";
      mode = "0400";
      restartUnits = [ "kanidm.service" ];
    }
  ) confidentialOidcClients;

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
      extraJsonFile = personMailProvisionFile;
      instanceUrl = "https://localhost:${toString kanidmPort}";
      groups = kanidmProvisionGroups;
      persons = kanidmProvisionPersons;
      systems.oauth2 = kanidmProvisionClients (
        clientId: config.sops.secrets."${kanidmOAuthSecretAttrName clientId}".path
      );
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
    pkiPkgs.reset-oidc
  ];

  networking.hosts."127.0.0.1" = [ kanidmLocalHost ];

  users.users.${mailSenderUser} = {
    isSystemUser = true;
    group = mailSenderGroup;
    home = mailSenderStateDir;
    createHome = false;
  };

  users.groups.${mailSenderGroup} = { };

  systemd.services.kanidm = {
    requires = [ "${personMailProvisionService}.service" ];
    wants = [ "sops-install-secrets.service" ];
    after = [
      "sops-install-secrets.service"
      "${personMailProvisionService}.service"
    ];
  };

  systemd.services.${personMailProvisionService} = {
    description = "Render Kanidm person email provisioning data";
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
    before = [ "kanidm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "kanidm";
      Group = "kanidm";
      RuntimeDirectory = personMailProvisionService;
      RuntimeDirectoryMode = "0700";
      UMask = "0077";
      ExecStart = "${lib.getExe personMailProvision} ${lib.escapeShellArgs personMailProvisionArgs}";
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [ "AF_UNIX" ];
    };
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
      ExecStart = "${lib.getExe' pkiPkgs.kanidm-mail-sender-bootstrap "kanidm-mail-sender-bootstrap"} ${
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
      pkiPkgs.kanidm-mail-sender-bootstrap
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
}
