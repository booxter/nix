{
  config,
  kanidmModel,
  lib,
  pkgs,
  ssoPkgs,
  ...
}:
let
  inherit (kanidmModel)
    confidentialOidcClients
    enabled
    idPublicHost
    kanidmLocalHost
    kanidmLocalUrl
    kanidmOAuthSecretAttrName
    kanidmOAuthSecretKey
    kanidmPort
    kanidmProvisionClients
    kanidmProvisionGroups
    kanidmProvisionPersons
    unknownOidcGroups
    ;
in
{
  config = lib.mkIf enabled {
    systemd.tmpfiles.rules = [
      "d /var/lib/kanidm/backups 0700 kanidm kanidm - -"
    ];

    host.backups.sources.kanidm.paths = [ "/var/lib/kanidm/backups" ];

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
    }
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
      package = pkgs.kanidmWithSecretProvisioning_1_11;
      server = {
        enable = true;
        settings = {
          adminbindpath = "/run/kanidmd/kanidm.socket";
          bindaddress = "127.0.0.1:${toString kanidmPort}";
          domain = idPublicHost;
          origin = "https://${idPublicHost}";
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
        systems.oauth2 = kanidmProvisionClients (
          clientId: config.sops.secrets.${kanidmOAuthSecretAttrName clientId}.path
        );
      };
    };

    host.web.services.id = {
      upstream = "https://127.0.0.1:${toString kanidmPort}";
      internal.locationExtraConfig = ''
        proxy_set_header Host ${idPublicHost};
        proxy_set_header X-Forwarded-Host ${idPublicHost};
      '';
    };

    environment.systemPackages = [
      config.services.kanidm.package
      ssoPkgs.reset-oidc
    ];

    networking.hosts."127.0.0.1" = [ kanidmLocalHost ];

    systemd.services.kanidm = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
