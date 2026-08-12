{
  config,
  facts,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.host.proxmox.apiCertificate;
  exporterCfg = config.host.proxmox.prometheusExporter;
  realmProxmox = facts.realms.${config.host.realm}.services.proxmox or null;
  certInstallUnit = "proxmox-api-certificate.service";
  internalPkiRootCaPath = config.host.internalPki.rootCaCertificate;
  sopsInstallSecretsUnit = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
  proxmoxHostTools = pkgs.callPackage ./pkgs/proxmox-host-tools { };
  certInstallCommand = utils.escapeSystemdExecArgs [
    (lib.getExe' proxmoxHostTools "proxmox-install-api-certificate")
    "--certificate-source"
    config.sops.secrets.proxmoxApiServerCrt.path
    "--certificate-destination"
    cfg.certificatePath
    "--key-source"
    config.sops.secrets.proxmoxApiServerKey.path
    "--key-destination"
    cfg.keyPath
  ];
in
{
  config = lib.mkMerge [
    {
      host.proxmox.apiCertificate.enable = lib.mkDefault (config.host.isProxmox && realmProxmox != null);
    }
    (lib.mkIf cfg.enable {
      host.internalPki.managedCertificates = [
        {
          category = "internal_https_server";
          name = "proxmox-api";
          inherit (cfg) secretPrefix;
          certificateField = "server_crt_unencrypted";
        }
      ];

      # Browser OIDC origins are scoped to nginx/443. pveproxy keeps its fixed
      # 8006 listener for Proxmox-native/root fallback access.
      host.web.services."proxmox-${config.networking.hostName}" = {
        enable = true;
        upstream = "https://127.0.0.1:${toString cfg.port}";
        internal = {
          endpointName = "proxmox";
          serverName = cfg.serverName;
          aliases = builtins.filter (alias: alias != cfg.serverName) cfg.serverAliases;
          localAliases = [ ];
          port = cfg.publicPort;
          secretPrefix = cfg.secretPrefix;
          locationExtraConfig = ''
            proxy_ssl_name ${cfg.serverName};
            proxy_ssl_server_name on;
            proxy_ssl_trusted_certificate ${internalPkiRootCaPath};
            proxy_ssl_verify on;
          '';
        };
        health.frontend.enable = true;
        presentation = {
          title = "Proxmox ${config.networking.hostName}";
          icon = "sh:proxmox";
        };
        metrics.default = {
          enable = true;
          endpointName = "pve";
          discover = false;
          jobName = "pve";
          openFirewall = exporterCfg.openFirewall;
          port = exporterCfg.publicPort;
          path = "/";
          upstream = "http://127.0.0.1:${toString exporterCfg.internalPort}";
        };
      };

      sops.secrets.proxmoxApiServerCrt = {
        key = "${cfg.secretPrefix}/server_crt_unencrypted";
        mode = "0400";
        restartUnits = [
          certInstallUnit
          "pveproxy.service"
        ];
      };
      sops.secrets.proxmoxApiServerKey = {
        key = "${cfg.secretPrefix}/server_key";
        mode = "0400";
        restartUnits = [
          certInstallUnit
          "pveproxy.service"
        ];
      };

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
    })
  ];
}
