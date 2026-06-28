{
  config,
  hostInventory,
  lib,
  ...
}:
let
  oidc = import ../../../lib/oidc-clients.nix { inherit lib hostInventory; };
  lan = hostInventory.site.lan;
  grafanaHost = "grafana.${lan.domain}";
  oidcClientId = oidc.clients.grafana.clientId;
  alertmanagerPort = 9093;
  grafanaPort = 3000;
  prometheusPort = 9090;
  lokiPort = 3100;
  grafanaAlertmanagerUid = "P3A7B7B4C0D9E6F1";
  grafanaPrometheusUid = "PBFA97CFB590B2093";
  grafanaLokiUid = "P8E80F9AEF21F6940";
in
{
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
  sops.secrets.grafanaOidcClientSecret = {
    key = "grafana/oidc/client_secret";
    owner = "grafana";
    group = "grafana";
    mode = "0400";
    restartUnits = [ "grafana.service" ];
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
        http_port = grafanaPort;
        domain = grafanaHost;
        root_url = "https://${grafanaHost}/";
      };
      security = {
        admin_user = "admin";
        admin_password = "$__file{${config.sops.secrets.grafanaAdminPassword.path}}";
        secret_key = "$__file{${config.sops.secrets.grafanaSecretKey.path}}";
      };
      auth = {
        disable_login_form = false;
      };
      "auth.generic_oauth" = {
        enabled = true;
        name = "SSO";
        icon = "signin";
        allow_sign_up = true;
        auto_login = false;
        client_id = oidcClientId;
        client_secret = "$__file{${config.sops.secrets.grafanaOidcClientSecret.path}}";
        scopes = lib.concatStringsSep " " oidc.baseScopes;
        auth_url = oidc.authorizationUrl;
        token_url = oidc.tokenUrl;
        api_url = oidc.userinfoUrl oidcClientId;
        auth_style = "InHeader";
        use_pkce = true;
        use_refresh_token = false;
        validate_id_token = true;
        jwk_set_url = oidc.jwksUrl oidcClientId;
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
            options.path = ./dashboards;
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

  host.internalHttps.services.grafana = {
    enable = true;
    upstream = "http://127.0.0.1:${toString grafanaPort}";
  };

  systemd.services.grafana = {
    wants = [ "sops-install-secrets.service" ];
    after = [ "sops-install-secrets.service" ];
  };
}
