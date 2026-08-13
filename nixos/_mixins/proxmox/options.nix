{
  config,
  hostSpec,
  lib,
  ...
}:
let
  oidcCfg = config.host.proxmox.oidc;
  guestSpec = (hostSpec.proxmox or { }).guest or null;
in
{
  options.host.proxmox = {
    controller.enable = lib.mkEnableOption "cluster-wide Proxmox integrations";

    cluster = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = (hostSpec.proxmox or { }).cluster or null;
      description = "Proxmox cluster claimed by this node or guest.";
    };

    guest = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = guestSpec != null;
        readOnly = true;
        internal = true;
        description = "Whether this host is managed as a declarative Proxmox guest.";
      };

      cores = lib.mkOption {
        type = lib.types.ints.positive;
        default = if guestSpec == null then 4 else guestSpec.cores or 4;
        description = "Virtual CPU cores assigned to the Proxmox guest.";
      };

      memoryGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = if guestSpec == null then 8 else guestSpec.memoryGiB or 8;
        description = "Memory assigned to the Proxmox guest, in GiB.";
      };

      balloonGiB = lib.mkOption {
        type = with lib.types; nullOr ints.positive;
        default = if guestSpec == null then null else guestSpec.balloonGiB or null;
        description = "Minimum ballooned memory for the Proxmox guest, in GiB.";
      };

      diskGiB = lib.mkOption {
        type = lib.types.ints.positive;
        default = if guestSpec == null then 100 else guestSpec.diskGiB or 100;
        description = "Root disk size assigned to the Proxmox guest, in GiB.";
      };
    };

    apiCertificate = {
      enable = lib.mkEnableOption "internal PKI certificate installation for the Proxmox VE API";

      serverName = lib.mkOption {
        type = lib.types.str;
        default = config.networking.hostName;
        description = "Primary DNS name used for the Proxmox VE API certificate.";
      };

      serverAliases = lib.mkOption {
        type = with lib.types; listOf str;
        default = lib.unique (
          [ "${config.services.avahi.hostName}.local" ] ++ hostSpec.certificateDnsNames
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

    oidc = {
      enable = lib.mkEnableOption "Kanidm OpenID Connect realm for Proxmox VE";

      realm = lib.mkOption {
        type = lib.types.str;
        default = "kanidm";
        description = "Proxmox VE realm identifier for Kanidm OIDC users.";
      };

      clientId = lib.mkOption {
        type = lib.types.str;
        default = "proxmox";
        description = "Kanidm OAuth2 client ID used by Proxmox VE.";
      };

      issuerUrl = lib.mkOption {
        type = lib.types.str;
        default = "https://id.${config.host.network.publicDomain}/oauth2/openid/${oidcCfg.clientId}";
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

    prometheusExporter = {
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
  };
}
