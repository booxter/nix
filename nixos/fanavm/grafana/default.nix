{
  config,
  hostInventory,
  ...
}:
let
  lan = hostInventory.site.lan;
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

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_addr = "127.0.0.1";
        http_port = grafanaPort;
        domain = "grafana.${lan.domain}";
        root_url = "https://grafana.${lan.domain}/";
      };
      security = {
        admin_user = "admin";
        admin_password = "$__file{${config.sops.secrets.grafanaAdminPassword.path}}";
        secret_key = "$__file{${config.sops.secrets.grafanaSecretKey.path}}";
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
            folder = "Fana";
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
