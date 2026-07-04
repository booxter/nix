{
  config,
  hostSpecName,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.proxmox.apiCertificate;
  exporterCfg = config.host.proxmox.prometheusExporter;
  oidc = import ../../../lib/oidc-clients.nix { inherit lib hostInventory; };
  oidcCfg = config.host.proxmox.oidc;
  oidcMappedAdminGroup = "${oidcCfg.allowedGroup}-${oidcCfg.realm}";
  oidcRealmUnit = "proxmox-oidc-realm.service";
  pveum = lib.getExe' config.services.proxmox-ve.package "pveum";
  hostSpec = hostInventory.nixosHostSpecsByName.${hostSpecName};
  hostCertificateDnsNames = hostInventory.toNixosHostCertificateDnsNames hostSpec;
  certInstallUnit = "proxmox-api-certificate.service";
  internalPkiRootCaPath = import ../../../lib/home-internal-pki-root-ca.nix;
  pveExporterGroup = config.services.prometheus.exporters.pve.group;
  pveExporterUser = config.services.prometheus.exporters.pve.user;
  sopsInstallSecretsUnit = lib.optional config.sops.useSystemdActivation "sops-install-secrets.service";
in
{
  options.host.proxmox.apiCertificate = {
    enable = lib.mkEnableOption "internal PKI certificate installation for the Proxmox VE API";

    serverName = lib.mkOption {
      type = lib.types.str;
      default = config.host.dnsName;
      description = "Primary DNS name used for the Proxmox VE API certificate.";
    };

    serverAliases = lib.mkOption {
      type = with lib.types; listOf str;
      default = lib.unique (
        [ "${config.services.avahi.hostName}.local" ]
        ++ hostCertificateDnsNames
        ++ (hostSpec.dnsAliases or [ ])
      );
      description = "Additional DNS names included in the Proxmox VE API certificate.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8006;
      description = "Proxmox VE API HTTPS port.";
    };

    publicPort = lib.mkOption {
      type = lib.types.port;
      default = 443;
      description = "LAN-visible HTTPS port fronted by nginx for browser and blackbox access.";
    };

    secretPrefix = lib.mkOption {
      type = lib.types.str;
      default = "proxmox/api";
      description = "SOPS key prefix containing server_crt_unencrypted and server_key for pveproxy.";
    };

    certificatePath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/pve/local/pveproxy-ssl.pem";
      description = "Custom pveproxy certificate path.";
    };

    keyPath = lib.mkOption {
      type = lib.types.str;
      default = "/etc/pve/local/pveproxy-ssl.key";
      description = "Custom pveproxy private key path.";
    };
  };

  options.host.proxmox.oidc = {
    enable = lib.mkEnableOption "Kanidm OpenID Connect realm for Proxmox VE";

    managerHost = lib.mkOption {
      type = lib.types.str;
      default = "prx1-lab";
      description = "Proxmox node that declaratively manages the cluster-wide OIDC realm.";
    };

    realm = lib.mkOption {
      type = lib.types.str;
      default = "kanidm";
      description = "Proxmox VE realm identifier for Kanidm OIDC users.";
    };

    clientId = lib.mkOption {
      type = lib.types.str;
      default = oidc.clients.proxmox.clientId;
      description = "Kanidm OAuth2 client ID used by Proxmox VE.";
    };

    issuerUrl = lib.mkOption {
      type = lib.types.str;
      default = oidc.openidBaseUrl oidcCfg.clientId;
      defaultText = "\${issuerBase}/oauth2/openid/\${clientId}";
      description = "OIDC issuer URL used by the Proxmox VE realm.";
    };

    clientSecretKey = lib.mkOption {
      type = lib.types.str;
      default = "proxmox/oidc/client_secret";
      description = "SOPS key containing the Kanidm OAuth2 client secret for Proxmox VE.";
    };

    usernameClaim = lib.mkOption {
      type = lib.types.str;
      default = "username";
      description = "OpenID claim used for Proxmox usernames.";
    };

    groupsClaim = lib.mkOption {
      type = lib.types.str;
      default = "infra_groups";
      description = "OpenID claim used for Proxmox group mapping.";
    };

    scopes = lib.mkOption {
      type = with lib.types; listOf str;
      default = [
        "email"
        "profile"
        "infra_groups"
      ];
      apply = lib.unique;
      description = "OIDC scopes requested by Proxmox VE.";
    };

    allowedGroup = lib.mkOption {
      type = lib.types.str;
      default = "infra-admins";
      description = "Kanidm group mapped to the Proxmox administrator role.";
    };

    role = lib.mkOption {
      type = lib.types.str;
      default = "Administrator";
      description = "Proxmox VE role granted to the mapped Kanidm group.";
    };

    aclPath = lib.mkOption {
      type = lib.types.str;
      default = "/";
      description = "Proxmox VE ACL path where the mapped Kanidm group is granted access.";
    };

    autocreateUsers = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Proxmox VE automatically creates OIDC users on first login.";
    };

    autocreateGroups = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether Proxmox VE automatically creates groups returned by the OIDC claim.";
    };

    overwriteGroups = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether OIDC group membership replaces existing Proxmox group membership on login.";
    };

    comment = lib.mkOption {
      type = lib.types.str;
      default = "Kanidm SSO";
      description = "Comment stored on the Proxmox VE OIDC realm.";
    };
  };

  options.host.proxmox.prometheusExporter = {
    enable = lib.mkEnableOption "per-node Proxmox VE Prometheus exporter";

    internalPort = lib.mkOption {
      type = lib.types.port;
      default = 19221;
      description = "Loopback-only prometheus-pve-exporter port.";
    };

    publicPort = lib.mkOption {
      type = lib.types.port;
      default = 9221;
      description = "LAN-visible mTLS port for Prometheus Proxmox VE scrapes.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to open the firewall for the mTLS exporter endpoint.";
    };

    apiUser = lib.mkOption {
      type = lib.types.str;
      default = "prometheus@pve";
      description = "Proxmox VE API user used by prometheus-pve-exporter.";
    };

    apiTokenName = lib.mkOption {
      type = lib.types.str;
      default = "metrics";
      description = "Proxmox VE API token name used by prometheus-pve-exporter.";
    };

    apiTokenValueSecret = lib.mkOption {
      type = lib.types.str;
      default = "proxmox/pve_exporter/token_value";
      description = "SOPS key containing the Proxmox VE API token value.";
    };

    verifySsl = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether prometheus-pve-exporter verifies the Proxmox VE API TLS certificate.";
    };
  };

  config = lib.mkMerge [
    {
      host.proxmox.apiCertificate.enable = lib.mkDefault (config.host.isProxmox && !config.host.isWork);
      host.proxmox.oidc.enable = lib.mkDefault (
        config.host.isProxmox && !config.host.isWork && hostSpecName == oidcCfg.managerHost
      );
      host.proxmox.prometheusExporter.enable = lib.mkDefault (
        config.host.isProxmox && !config.host.isWork
      );
    }
    (lib.mkIf cfg.enable {
      assertions = [
        {
          assertion = config.services.proxmox-ve.enable;
          message = "host.proxmox.apiCertificate requires services.proxmox-ve.enable.";
        }
      ];

      # Browser OIDC origins are scoped to nginx/443. pveproxy keeps its fixed
      # 8006 listener for Proxmox-native/root fallback access.
      host.internalHttps.services.proxmox = {
        enable = true;
        serverName = cfg.serverName;
        serverAliases = builtins.filter (alias: alias != cfg.serverName) cfg.serverAliases;
        localAliases = [ ];
        port = cfg.publicPort;
        secretPrefix = cfg.secretPrefix;
        upstream = "https://127.0.0.1:${toString cfg.port}";
        locationExtraConfig = ''
          proxy_ssl_name ${cfg.serverName};
          proxy_ssl_server_name on;
          proxy_ssl_trusted_certificate ${internalPkiRootCaPath};
          proxy_ssl_verify on;
        '';
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
        path = with pkgs; [
          coreutils
        ];
        script = ''
          set -euo pipefail
          cert_path=${lib.escapeShellArg (toString cfg.certificatePath)}
          key_path=${lib.escapeShellArg (toString cfg.keyPath)}

          cleanup() {
            rm -f \
              "$cert_path.tmp.$$" "$key_path.tmp.$$" \
              "$cert_path.probe.$$" "$key_path.probe.$$"
          }
          trap cleanup EXIT

          wait_pmxcfs_writable() {
            dst="$1"
            probe="$dst.probe.$$"

            for attempt in $(seq 1 60); do
              if : > "$probe" 2>/dev/null; then
                rm -f "$probe"
                return 0
              fi

              if [ "$attempt" -eq 1 ]; then
                echo "waiting for writable Proxmox cluster filesystem before installing $dst" >&2
              fi
              sleep 1
            done

            echo "timed out waiting for writable Proxmox cluster filesystem before installing $dst" >&2
            return 1
          }

          # /etc/pve is Proxmox pmxcfs, which rejects normal chmod/chown
          # operations. Copy files into it and let pmxcfs assign its own
          # root:www-data permissions.
          copy_pmxcfs() {
            src="$1"
            dst="$2"
            tmp="$dst.tmp.$$"

            wait_pmxcfs_writable "$dst"
            cp "$src" "$tmp"
            mv -f "$tmp" "$dst"
          }

          copy_pmxcfs ${config.sops.secrets.proxmoxApiServerCrt.path} "$cert_path"
          copy_pmxcfs ${config.sops.secrets.proxmoxApiServerKey.path} "$key_path"
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
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
    (lib.mkIf oidcCfg.enable {
      assertions = [
        {
          assertion = config.services.proxmox-ve.enable;
          message = "host.proxmox.oidc requires services.proxmox-ve.enable.";
        }
        {
          assertion = builtins.hasAttr oidcCfg.clientId oidc.clients;
          message = "host.proxmox.oidc.clientId must exist in lib/oidc-clients.nix.";
        }
        {
          assertion = oidcCfg.scopes != [ ];
          message = "host.proxmox.oidc.scopes must not be empty.";
        }
      ];

      sops.secrets.proxmoxOidcClientSecret = {
        key = oidcCfg.clientSecretKey;
        mode = "0400";
        restartUnits = [ oidcRealmUnit ];
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
        path = with pkgs; [
          coreutils
          jq
        ];
        script = ''
          set -euo pipefail

          realm=${lib.escapeShellArg oidcCfg.realm}
          mapped_group=${lib.escapeShellArg oidcMappedAdminGroup}
          group_comment=${lib.escapeShellArg "Kanidm ${oidcCfg.allowedGroup} OIDC group"}
          acl_path=${lib.escapeShellArg oidcCfg.aclPath}
          role=${lib.escapeShellArg oidcCfg.role}
          pveum=${lib.escapeShellArg pveum}
          client_key="$(tr -d '\n' < ${lib.escapeShellArg config.sops.secrets.proxmoxOidcClientSecret.path})"

          cleanup() {
            rm -f "/etc/pve/.proxmox-oidc-realm.probe.$$"
          }
          trap cleanup EXIT

          wait_pmxcfs_writable() {
            probe="/etc/pve/.proxmox-oidc-realm.probe.$$"

            for attempt in $(seq 1 60); do
              if : > "$probe" 2>/dev/null; then
                rm -f "$probe"
                return 0
              fi

              if [ "$attempt" -eq 1 ]; then
                echo "waiting for writable Proxmox cluster filesystem before configuring OIDC" >&2
              fi
              sleep 1
            done

            echo "timed out waiting for writable Proxmox cluster filesystem before configuring OIDC" >&2
            return 1
          }

          wait_pmxcfs_writable

          realm_common_args=(
            --issuer-url ${lib.escapeShellArg oidcCfg.issuerUrl}
            --client-id ${lib.escapeShellArg oidcCfg.clientId}
            --client-key "$client_key"
            --autocreate ${if oidcCfg.autocreateUsers then "1" else "0"}
            --groups-claim ${lib.escapeShellArg oidcCfg.groupsClaim}
            --groups-autocreate ${if oidcCfg.autocreateGroups then "1" else "0"}
            --groups-overwrite ${if oidcCfg.overwriteGroups then "1" else "0"}
            --scopes ${lib.escapeShellArg (lib.concatStringsSep " " oidcCfg.scopes)}
            --comment ${lib.escapeShellArg oidcCfg.comment}
          )

          if "$pveum" realm list --output-format json \
            | jq -e --arg realm "$realm" '.[] | select((.realm // .realmid // .id) == $realm)' >/dev/null; then
            "$pveum" realm modify "$realm" "''${realm_common_args[@]}"
          else
            "$pveum" realm add "$realm" \
              --type openid \
              --username-claim ${lib.escapeShellArg oidcCfg.usernameClaim} \
              "''${realm_common_args[@]}"
          fi

          if ! "$pveum" group list --output-format json \
            | jq -e --arg group "$mapped_group" '.[] | select((.groupid // .group // .id) == $group)' >/dev/null; then
            "$pveum" group add "$mapped_group" --comment "$group_comment"
          fi

          "$pveum" aclmod "$acl_path" -groups "$mapped_group" -roles "$role"
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
        };
      };
    })
    (lib.mkIf exporterCfg.enable {
      assertions = [
        {
          assertion = config.services.proxmox-ve.enable;
          message = "host.proxmox.prometheusExporter requires services.proxmox-ve.enable.";
        }
      ];

      sops.secrets.proxmoxPveExporterTokenValue = {
        key = exporterCfg.apiTokenValueSecret;
        owner = pveExporterUser;
        group = pveExporterGroup;
        mode = "0400";
        restartUnits = [ "prometheus-pve-exporter.service" ];
      };

      sops.templates."pve-exporter.env" = {
        owner = pveExporterUser;
        group = pveExporterGroup;
        mode = "0400";
        content = ''
          PVE_USER=${exporterCfg.apiUser}
          PVE_TOKEN_NAME=${exporterCfg.apiTokenName}
          PVE_TOKEN_VALUE=${config.sops.placeholder.proxmoxPveExporterTokenValue}
          PVE_VERIFY_SSL=${lib.boolToString exporterCfg.verifySsl}
        '';
        restartUnits = [ "prometheus-pve-exporter.service" ];
      };

      services.prometheus.exporters.pve = {
        enable = true;
        listenAddress = "127.0.0.1";
        port = exporterCfg.internalPort;
        environmentFile = config.sops.templates."pve-exporter.env".path;
      };

      systemd.services.prometheus-pve-exporter = {
        wants = [
          certInstallUnit
          "pveproxy.service"
        ]
        ++ sopsInstallSecretsUnit;
        after = [
          certInstallUnit
          "pveproxy.service"
        ]
        ++ sopsInstallSecretsUnit;
        environment.REQUESTS_CA_BUNDLE = toString internalPkiRootCaPath;
      };

      host.observability.client.prometheusMtlsEndpoints.pve = {
        enable = true;
        port = exporterCfg.publicPort;
        path = "/";
        upstream = "http://127.0.0.1:${toString exporterCfg.internalPort}";
        openFirewall = exporterCfg.openFirewall;
      };
    })
  ];
}
