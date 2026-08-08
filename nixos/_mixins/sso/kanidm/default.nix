{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.sso.provider;
  idService = hostInventory.servicesById.id;
  kanidmPort = 18085;
  kanidmLocalHost = idService.id;
  kanidmLocalUrl = "https://${kanidmLocalHost}:${toString kanidmPort}";
in
{
  imports = [
    ./backup.nix
    ./identities.nix
    ./mail-sender.nix
    ./oidc.nix
    ./reset-credentials.nix
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

    host.internalService.services.id = {
      enable = true;
      upstream = "https://127.0.0.1:${toString kanidmPort}";
      publicAliases = [ idService.publicHost ];
      mtls.enable = true;
      locationExtraConfig = ''
        proxy_set_header Host ${idService.publicHost};
        proxy_set_header X-Forwarded-Host ${idService.publicHost};
      '';
    };

    environment.systemPackages = [ config.services.kanidm.package ];

    networking.hosts."127.0.0.1" = [ kanidmLocalHost ];

    systemd.services.kanidm = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };

  };
}
