{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.grafana;
  grafanaHost = "grafana.${config.host.network.lanDomain}";
  oidcClient = config.host.sso.oidc.clients.grafana;
  oidcScopes = config.host.sso.oidc.baseScopes;
  alertmanagerPort = config.host.observability.alertmanager.port;
  prometheusPort = config.host.observability.prometheus.server.port;
  lokiPort = config.host.observability.loki.server.port;
  grafanaAlertmanagerUid = "P3A7B7B4C0D9E6F1";
  grafanaPrometheusUid = "PBFA97CFB590B2093";
  grafanaLokiUid = "P8E80F9AEF21F6940";
  localHost = config.networking.hostName;
  nixosConfigurations = outputs.nixosConfigurations // {
    ${localHost} = { inherit config; };
  };
  fleetConfigurations = nixosConfigurations // outputs.darwinConfigurations;
  observableConfigurations = lib.filterAttrs (
    _: configuration:
    configuration.config.host.realm == config.host.realm
    && configuration.config.host.observability.enable
  ) fleetConfigurations;
  dashboardHost =
    name: configuration:
    let
      hostConfig = configuration.config;
      enabledServices = lib.filterAttrs (_: service: service.enable) (
        hostConfig.host.web.services or { }
      );
      gpuVendors = hostConfig.host.hardware.gpu.vendors or [ ];
      fileSystems = builtins.attrValues (hostConfig.fileSystems or { });
      diskBays = hostConfig.host.hardware.storage.diskBays or null;
    in
    {
      inherit name;
      platform = if hostConfig.nixpkgs.hostPlatform.isDarwin then "darwin" else "linux";
      virtual = hostConfig.host.proxmox.guest.enable;
      builder = hostConfig.host.nix.builder.enable;
      hypervisor = hostConfig.host.proxmox.node.enable;
      gpuVendor = if gpuVendors == [ ] then null else lib.head gpuVendors;
      services = builtins.attrNames enabledServices;
      storage = {
        btrfs = builtins.any (fileSystem: (fileSystem.fsType or null) == "btrfs") fileSystems;
        diskBays =
          if diskBays == null then
            null
          else
            {
              inherit (diskBays) columns rows;
            };
        nvme = false;
      };
      backups = {
        client = (hostConfig.host.backups.jobs or { }) != { };
        server = hostConfig.host.backups.server.enable or false;
      };
    };
  dashboardManifest = {
    dataSources = {
      prometheus = {
        type = "prometheus";
        uid = grafanaPrometheusUid;
      };
      loki = {
        type = "loki";
        uid = grafanaLokiUid;
      };
    };
    hosts = lib.mapAttrsToList dashboardHost observableConfigurations;
    network.internet = {
      ingress = {
        capacityMbit = config.host.site.uplink.downloadMbit;
        targetMbit = config.host.site.policies.downloaders.maxDownloadMbit;
      };
      egress = {
        capacityMbit = config.host.site.uplink.uploadMbit;
        targetMbit = config.host.site.policies.backups.maxUploadMbit;
      };
    };
  };
  dashboardConfig = pkgs.writeText "grafana-dashboard-config.json" (
    builtins.toJSON dashboardManifest
  );
  dashboardGenerator = pkgs.callPackage ./dashboard-generator/package.nix { };
  dashboardDirectory = pkgs.runCommandLocal "fana-grafana-dashboards" { } ''
    mkdir "$out"
    ${lib.getExe dashboardGenerator} --config ${dashboardConfig} --output "$out"
  '';
in
{
  options.host.observability.grafana = {
    enable = lib.mkEnableOption "a Grafana server";
    port = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      readOnly = true;
      internal = true;
      description = "Loopback Grafana HTTP port.";
    };
    endpoint = lib.mkOption {
      type = with lib.types; nullOr nonEmptyStr;
      default = if cfg.enable then config.host.web.services.grafana.internal.url else null;
      readOnly = true;
      internal = true;
      description = "Resolved HTTPS endpoint published to Grafana clients.";
    };
  };

  config = lib.mkIf cfg.enable {
    host.web.services.grafana.auth = {
      mode = "oidc";
      oidcRegistration = {
        displayName = "Grafana";
        originUrls = [ "https://${grafanaHost}/login/generic_oauth" ];
        originLanding = "https://${grafanaHost}/";
        scopeMaps = {
          "grafana-admins" = oidcScopes;
          "grafana-viewers" = oidcScopes;
        };
        claimMaps.grafana_role.valuesByGroup = {
          "grafana-admins" = [ "admin" ];
          "grafana-viewers" = [ "viewer" ];
        };
        secret = {
          sopsKey = "grafana/oidc/client_secret";
          name = "grafanaOidcClientSecret";
          owner = "grafana";
          group = "grafana";
          restartUnits = [ "grafana.service" ];
        };
      };
    };

    sops.secrets.grafanaSecretKey = {
      key = "grafana/secret_key";
      owner = "grafana";
      group = "grafana";
      mode = "0400";
    };
    sops.secrets.grafanaAdminPassword = {
      key = "grafana/admin_password";
      owner = "grafana";
      group = "grafana";
      mode = "0400";
    };
    services.grafana = {
      enable = true;
      settings = {
        database = {
          # Reduce transient SQLITE_BUSY failures during concurrent dashboard refreshes.
          wal = true;
          query_retries = 5;
          transaction_retries = 10;
        };
        server = {
          http_addr = "127.0.0.1";
          http_port = cfg.port;
          domain = grafanaHost;
          enforce_domain = true;
          root_url = "https://${grafanaHost}/";
        };
        security = {
          admin_user = "admin";
          admin_password = "$__file{${config.sops.secrets.grafanaAdminPassword.path}}";
          secret_key = "$__file{${config.sops.secrets.grafanaSecretKey.path}}";
        };
        auth = {
          disable_login_form = true;
        };
        "auth.basic" = {
          enabled = false;
        };
        "auth.generic_oauth" = {
          enabled = true;
          name = "SSO";
          icon = "signin";
          allow_sign_up = true;
          auto_login = false;
          client_id = oidcClient.clientId;
          client_secret = "$__file{${oidcClient.secret.path}}";
          scopes = lib.concatStringsSep " " oidcClient.baseScopes;
          auth_url = oidcClient.authorizationUrl;
          token_url = oidcClient.tokenUrl;
          api_url = oidcClient.userinfoUrl;
          auth_style = "InHeader";
          use_pkce = true;
          use_refresh_token = false;
          validate_id_token = true;
          jwk_set_url = oidcClient.jwksUrl;
          login_attribute_path = "preferred_username";
          name_attribute_path = "name";
          email_attribute_path = "email";
          role_attribute_path = "contains(grafana_role[*], 'admin') && 'GrafanaAdmin' || contains(grafana_role[*], 'viewer') && 'Viewer' || 'None'";
          role_attribute_strict = true;
          allow_assign_grafana_admin = true;
          skip_org_role_sync = false;
        };
        analytics = {
          reporting_enabled = false;
          check_for_updates = false;
          check_for_plugin_updates = false;
        };
        plugins = {
          preinstall_disabled = true;
        };
      };
      provision = {
        enable = true;
        datasources.settings = {
          apiVersion = 1;
          datasources = [
            {
              name = "Prometheus";
              uid = grafanaPrometheusUid;
              type = "prometheus";
              access = "proxy";
              url = "http://127.0.0.1:${toString prometheusPort}";
              isDefault = true;
              jsonData = {
                manageAlerts = true;
                alertmanagerUid = grafanaAlertmanagerUid;
              };
              editable = false;
            }
            {
              name = "Alertmanager";
              uid = grafanaAlertmanagerUid;
              type = "alertmanager";
              access = "proxy";
              url = "http://127.0.0.1:${toString alertmanagerPort}";
              jsonData = {
                implementation = "prometheus";
                handleGrafanaManagedAlerts = false;
              };
              editable = false;
            }
            {
              name = "Loki";
              uid = grafanaLokiUid;
              type = "loki";
              access = "proxy";
              url = "http://127.0.0.1:${toString lokiPort}";
              jsonData = {
                manageAlerts = false;
              };
              editable = false;
            }
          ];
        };
        dashboards.settings = {
          apiVersion = 1;
          providers = [
            {
              name = "fana";
              type = "file";
              disableDeletion = false;
              editable = false;
              updateIntervalSeconds = 30;
              options = {
                path = dashboardDirectory;
                foldersFromFilesStructure = true;
              };
            }
          ];
        };
        alerting.rules.settings = {
          apiVersion = 1;
          deleteRules = [
            {
              orgId = 1;
              uid = "dns_upstream_failures";
            }
            {
              orgId = 1;
              uid = "dns_probe_down";
            }
            {
              orgId = 1;
              uid = "ups_exporter_down";
            }
            {
              orgId = 1;
              uid = "ups_on_battery";
            }
            {
              orgId = 1;
              uid = "ups_low_battery";
            }
            {
              orgId = 1;
              uid = "internal_pki_cert_missing";
            }
            {
              orgId = 1;
              uid = "internal_pki_cert_expiry_warning";
            }
            {
              orgId = 1;
              uid = "internal_pki_cert_expiry_critical";
            }
            {
              orgId = 1;
              uid = "public_tls_cert_expiry_warning";
            }
            {
              orgId = 1;
              uid = "public_tls_cert_expiry_critical";
            }
            {
              orgId = 1;
              uid = "pki_rotation_controller_failed";
            }
            {
              orgId = 1;
              uid = "pki_rotation_controller_stale";
            }
            {
              orgId = 1;
              uid = "thermal_cpu_hot";
            }
            {
              orgId = 1;
              uid = "thermal_storage_hot";
            }
            {
              orgId = 1;
              uid = "thermal_hba_export_failed";
            }
            {
              orgId = 1;
              uid = "thermal_hdd_hot";
            }
            {
              orgId = 1;
              uid = "darwin_ismc_export_failed";
            }
          ];
          groups = [
          ];
        };
      };
    };

    host.web.services.grafana = {
      enable = true;
      upstream = "http://127.0.0.1:${toString cfg.port}";
      health.frontend = {
        enable = true;
        path = "/login";
      };
      dashboard = {
        enable = true;
        section = "infrastructure";
      };
    };

    systemd.services.grafana = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
    };
  };
}
