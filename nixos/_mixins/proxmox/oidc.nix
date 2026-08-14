{
  config,
  lib,
  outputs,
  pkgs,
  proxmoxModel,
  utils,
  ...
}:
let
  node = config.host.proxmox.node;
  enabled = node != null && node.controller && config.host.realm == "home";
  realm = "kanidm";
  clientId = "proxmox";
  issuerUrl = "https://id.${config.host.network.publicDomain}/oauth2/openid/${clientId}";
  clientSecretKey = "proxmox/oidc/client_secret";
  usernameClaim = "username";
  groupsClaim = "infra_groups";
  scopes = [
    "email"
    "profile"
    groupsClaim
  ];
  allowedGroup = "infra-admins";
  role = "Administrator";
  oidcScopes = config.host.sso.oidc.baseScopes;
  oidcMappedAdminGroup = "${allowedGroup}-${realm}";
  oidcRealmUnit = "proxmox-oidc-realm.service";
  pveum = lib.getExe' config.services.proxmox-ve.package "pveum";
  sopsInstallSecretsUnit = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
  proxmoxHostTools = pkgs.callPackage ./pkgs/proxmox-host-tools { };
  topology = proxmoxModel;
  certificateDnsNamesFor =
    name:
    if name == config.networking.hostName then
      config.host.network.certificateDnsNames
    else
      outputs.nixosConfigurations.${name}.config.host.network.certificateDnsNames;
  proxmoxLabHosts = lib.unique (lib.concatMap certificateDnsNamesFor topology.nodeNames);
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
    inherit realm scopes role;
    issuer_url = issuerUrl;
    client_id = clientId;
    autocreate_users = true;
    groups_claim = groupsClaim;
    autocreate_groups = true;
    overwrite_groups = true;
    comment = "Kanidm SSO";
    username_claim = usernameClaim;
    mapped_group = oidcMappedAdminGroup;
    group_comment = "Kanidm ${allowedGroup} OIDC group";
    acl_path = "/";
  };
  oidcRealmCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' proxmoxHostTools "proxmox-configure-oidc")
    "--config"
    oidcRealmConfig
  ];
in
{
  config = lib.mkIf enabled {
    host.sso.oidc.registrations.proxmox = {
      displayName = "Proxmox VE";
      originUrls = proxmoxOriginUrls;
      originLanding = "https://${proxmoxCanonicalHost}/";
      scopeMaps.${allowedGroup} = oidcScopes ++ [ groupsClaim ];
      claimMaps.${groupsClaim}.valuesByGroup.${allowedGroup} = [
        allowedGroup
      ];
      secret = {
        sopsKey = clientSecretKey;
        name = "proxmoxOidcClientSecret";
        restartUnits = [ oidcRealmUnit ];
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
  };
}
