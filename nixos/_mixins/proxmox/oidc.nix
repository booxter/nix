{
  config,
  facts,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.proxmox.oidc;
  oidcScopes = config.host.sso.oidc.baseScopes;
  oidcMappedAdminGroup = "${cfg.allowedGroup}-${cfg.realm}";
  oidcRealmUnit = "proxmox-oidc-realm.service";
  pveum = lib.getExe' config.services.proxmox-ve.package "pveum";
  sopsInstallSecretsUnit = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
  proxmoxHostTools = pkgs.callPackage ./pkgs/proxmox-host-tools { };
  proxmoxLabHostSpecs = builtins.filter (spec: (spec.hostKind or null) == "proxmox") (
    builtins.attrValues facts.hosts.nixos
  );
  proxmoxLabHosts = lib.unique (lib.concatMap (spec: spec.certificateDnsNames) proxmoxLabHostSpecs);
  proxmoxCanonicalHost = "proxmox.${config.host.network.lanDomain}";
  proxmoxOriginUrls = lib.unique (
    [
      "https://${proxmoxCanonicalHost}"
      "https://proxmox"
    ]
    ++ map (host: "https://${host}") proxmoxLabHosts
  );
  oidcRealmConfig = (pkgs.formats.json { }).generate "proxmox-oidc-realm.json" {
    inherit pveum;
    pmxcfs_directory = "/etc/pve";
    client_secret_file = config.sops.secrets.proxmoxOidcClientSecret.path;
    realm = cfg.realm;
    issuer_url = cfg.issuerUrl;
    client_id = cfg.clientId;
    autocreate_users = cfg.autocreateUsers;
    groups_claim = cfg.groupsClaim;
    autocreate_groups = cfg.autocreateGroups;
    overwrite_groups = cfg.overwriteGroups;
    scopes = cfg.scopes;
    comment = cfg.comment;
    username_claim = cfg.usernameClaim;
    mapped_group = oidcMappedAdminGroup;
    group_comment = "Kanidm ${cfg.allowedGroup} OIDC group";
    acl_path = cfg.aclPath;
    role = cfg.role;
  };
  oidcRealmCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' proxmoxHostTools "proxmox-configure-oidc")
    "--config"
    oidcRealmConfig
  ];
in
{
  config = lib.mkMerge [
    {
      host.proxmox.oidc.enable = lib.mkDefault (
        config.host.isProxmox && config.host.proxmox.controller.enable
      );
    }
    (lib.mkIf cfg.enable {
      host.web.services."proxmox-${config.networking.hostName}".auth = {
        mode = "oidc";
        registrationName = "proxmox";
        oidcRegistration = {
          clientId = cfg.clientId;
          displayName = "Proxmox VE";
          originUrls = proxmoxOriginUrls;
          originLanding = "https://${proxmoxCanonicalHost}/";
          scopeMaps.${cfg.allowedGroup} = oidcScopes ++ [ cfg.groupsClaim ];
          claimMaps.${cfg.groupsClaim}.valuesByGroup.${cfg.allowedGroup} = [
            cfg.allowedGroup
          ];
          secret = {
            sopsKey = cfg.clientSecretKey;
            name = "proxmoxOidcClientSecret";
            restartUnits = [ oidcRealmUnit ];
          };
        };
      };

      systemd.services.proxmox-oidc-realm = {
        description = "Configure Proxmox VE Kanidm OIDC realm";
        wantedBy = [ "multi-user.target" ];
        requires = [ "pve-cluster.service" ] ++ sopsInstallSecretsUnit;
        after = [
          "pve-cluster.service"
          "corosync.service"
        ]
        ++ sopsInstallSecretsUnit;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
          ExecStart = oidcRealmCommand;
        };
      };
    })
  ];
}
