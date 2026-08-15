{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  node = config.host.proxmox.node;
  enabled = node != null && config.host.realm == "home";
  serverName = if node == null then config.networking.hostName else node.apiServerName;
  serverAliases = lib.unique (
    [ "${config.services.avahi.hostName}.local" ] ++ config.host.network.certificateDnsNames
  );
  port = 8006;
  secretPrefix = "proxmox/api";
  certificatePath = "/etc/pve/local/pveproxy-ssl.pem";
  keyPath = "/etc/pve/local/pveproxy-ssl.key";
  certInstallUnit = "proxmox-api-certificate.service";
  certificateSecret = "internal-https-proxmox-server-crt";
  keySecret = "internal-https-proxmox-server-key";
  pkiRootCaPath = config.host.pki.authority.rootCaCertificate;
  sopsInstallSecretsUnit = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
  proxmoxHostTools = pkgs.callPackage ./pkgs/proxmox-host-tools { };
  certInstallCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' proxmoxHostTools "proxmox-install-api-certificate")
    "--certificate-source"
    config.sops.secrets.${certificateSecret}.path
    "--certificate-destination"
    certificatePath
    "--key-source"
    config.sops.secrets.${keySecret}.path
    "--key-destination"
    keyPath
  ];
in
{
  config = lib.mkIf enabled {
    # Browser OIDC origins are scoped to nginx/443. pveproxy keeps its fixed
    # 8006 listener for Proxmox-native/root fallback access.
    host.web.services."proxmox-${config.networking.hostName}" = {
      upstream = "https://127.0.0.1:${toString port}";
      internal = {
        endpointName = "proxmox";
        inherit serverName secretPrefix;
        aliases = builtins.filter (alias: alias != serverName) serverAliases;
        localAliases = [ ];
        locationExtraConfig = ''
          proxy_ssl_name ${serverName};
          proxy_ssl_server_name on;
          proxy_ssl_trusted_certificate ${pkiRootCaPath};
          proxy_ssl_verify on;
        '';
      };
      health.frontend = { };
      displayName = "Proxmox ${config.networking.hostName}";
    };

    sops.secrets.${certificateSecret}.restartUnits = [
      certInstallUnit
      "pveproxy.service"
    ];
    sops.secrets.${keySecret}.restartUnits = [
      certInstallUnit
      "pveproxy.service"
    ];

    systemd.services.proxmox-api-certificate = {
      description = "Install internal PKI certificate for Proxmox VE API";
      wantedBy = [ "multi-user.target" ];
      requiredBy = [ "pveproxy.service" ];
      before = [ "pveproxy.service" ];
      requires = [ "pve-cluster.service" ] ++ sopsInstallSecretsUnit;
      after = [
        "pve-cluster.service"
        "corosync.service"
      ]
      ++ sopsInstallSecretsUnit;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = certInstallCommand;
      };
    };

    systemd.services.pveproxy = {
      # proxmox-nixos starts pveproxy as a weak dependency of other Proxmox
      # units, but switch activation may stop changed services without
      # re-starting units that are not directly wanted. Keep the API proxy a
      # first-class boot target because nginx/443 and exporters depend on it.
      wantedBy = [ "multi-user.target" ];
    };
  };
}
