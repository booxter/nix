{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.logs;
  clientCfg = config.host.observability.client;
  internalPkiRootCaPath = import ../../../lib/home-internal-pki-root-ca.nix;
  enabledMtlsClients = lib.filterAttrs (_: client: client.enable) clientCfg.mtlsClients;
  lokiMtlsClient =
    if cfg.loki.mtls.enable && builtins.hasAttr cfg.loki.mtls.clientName enabledMtlsClients then
      enabledMtlsClients.${cfg.loki.mtls.clientName}
    else
      null;
  stateDir = "/var/lib/grafana-alloy";
  hostLabel = config.host.dnsName;
  renderLabelMap =
    labels:
    "{ ${
      lib.concatStringsSep ", " (
        lib.mapAttrsToList (name: value: "${builtins.toJSON name} = ${builtins.toJSON value}") labels
      )
    } }";
  logTargets = map (
    path:
    {
      "__path__" = path;
      job = cfg.jobName;
      host = hostLabel;
    }
    // cfg.extraLabels
  ) cfg.fileGlobs;
  lokiTlsConfig = lib.optionalString cfg.loki.mtls.enable ''
    tls_config {
      ca_file = "${cfg.loki.mtls.trustedCaCertificate}"
      cert_file = "${config.sops.secrets.observabilityLokiClientCrt.path}"
      key_file = "${config.sops.secrets.observabilityLokiClientKey.path}"
      server_name = "${cfg.loki.mtls.serverName}"
    }
  '';
  alloyConfig = pkgs.writeText "darwin-file-logs.alloy" ''
    loki.write "default" {
      endpoint {
        url = "${cfg.lokiWriteUrl}"
    ${lokiTlsConfig}
      }
    }

    loki.process "darwin_service_labels" {
      forward_to = [loki.write.default.receiver]

      // Raw launchd stdout/stderr logs often have no process prefix; use the
      // basename as a fallback and let line parsers below override it.
      stage.regex {
        source     = "filename"
        expression = "^.+/(?P<service_name>[^/]+)\\.log$"
      }

      // /var/log/wifi.log style: Tue Jun 16 09:40:42.876 [airport]/671 ...
      stage.regex {
        expression = "^[A-Z][a-z]{2} [A-Z][a-z]{2} [ 0-9][0-9] [0-9:.]+ \\[(?P<service_name>[^]/]+)\\]/[0-9]+"
      }

      // /var/log/system.log style: Jun 16 09:40:42 host process[123]: ...
      stage.regex {
        expression = "^[A-Z][a-z]{2} [ 0-9][0-9] [0-9:.]+ [^ ]+ (?P<service_name>[^\\s\\[:]+)(?:\\[[0-9]+\\])?:"
      }

      // install.log and launchd stdout/stderr style: 2026-06-16 09:40:42 host process[123]: ...
      stage.regex {
        expression = "^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:.+-]+(?: [^ ]+)? (?P<service_name>[^\\s\\[:]+)(?:\\[[0-9]+\\])?:"
      }

      stage.labels {
        values = {
          service_name = "",
        }
      }
    }

    loki.source.file "darwin_files" {
      targets = [
        ${lib.concatMapStringsSep "\n    " (target: "${renderLabelMap target},") logTargets}
      ]
      forward_to    = [loki.process.darwin_service_labels.receiver]
      tail_from_end = true

      file_match {
        enabled = true
      }
    }
  '';
in
{
  options.host.observability.logs = {
    enable = lib.mkEnableOption "Darwin file log shipping to Loki";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.grafana-alloy;
      description = "Grafana Alloy package used to ship Darwin file logs.";
    };

    lokiWriteUrl = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "Loki push endpoint URL for Darwin file log shipping.";
    };

    loki.mtls = {
      enable = lib.mkEnableOption "mTLS authentication for Loki log shipping";

      clientName = lib.mkOption {
        type = lib.types.str;
        default = "loki";
        description = "Name of the host.observability.client.mtlsClients entry used for Loki writes.";
      };

      serverName = lib.mkOption {
        type = lib.types.str;
        default = "loki.${hostInventory.site.lan.domain}";
        description = "TLS server name used for Loki writes.";
      };

      trustedCaCertificate = lib.mkOption {
        type = lib.types.path;
        default = internalPkiRootCaPath;
        description = "CA bundle used to verify the Loki writer endpoint.";
      };
    };

    fileGlobs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [
        "/var/log/*.log"
        "/private/var/lib/prometheus-node-exporter/*.log"
      ];
      description = "Absolute file globs to tail and ship to Loki.";
    };

    jobName = lib.mkOption {
      type = lib.types.str;
      default = "darwin-file-log";
      description = "Loki job label applied to Darwin file log entries.";
    };

    extraLabels = lib.mkOption {
      type = with lib.types; attrsOf str;
      default = { };
      description = "Additional static Loki labels applied to Darwin file log entries.";
    };

    configFile = lib.mkOption {
      type = lib.types.path;
      default = alloyConfig;
      description = "Generated Grafana Alloy configuration for Darwin file log shipping.";
    };

    httpListenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1:12345";
      description = "Grafana Alloy local HTTP listen address.";
    };
  };

  config = lib.mkMerge [
    {
      host.observability.logs = {
        enable = lib.mkDefault (!config.host.isWork);
        lokiWriteUrl = lib.mkDefault "https://loki.${hostInventory.site.lan.domain}/loki/api/v1/push";
        loki.mtls.enable = lib.mkDefault (cfg.enable && cfg.lokiWriteUrl != null);
      };

      host.observability.client.mtlsClients.loki = {
        enable = lib.mkDefault (cfg.enable && cfg.lokiWriteUrl != null && cfg.loki.mtls.enable);
        secretPrefix = "observability/clients/loki";
      };
    }
    (lib.mkIf (cfg.enable && cfg.lokiWriteUrl != null) (
      lib.mkMerge [
        {
          system.activationScripts.postActivation.text = lib.mkAfter ''
            mkdir -p ${stateDir}
            chmod 0755 ${stateDir}
          '';

          launchd.daemons.grafana-alloy-logs = {
            command = lib.escapeShellArgs [
              (lib.getExe cfg.package)
              "run"
              "--server.http.listen-addr=${cfg.httpListenAddress}"
              "--storage.path=${stateDir}"
              cfg.configFile
            ];
            serviceConfig = {
              RunAtLoad = true;
              KeepAlive = true;
              WorkingDirectory = stateDir;
              EnvironmentVariables = {
                HOME = "/var/root";
              };
              ProcessType = "Background";
              StandardOutPath = "/var/log/grafana-alloy.log";
              StandardErrorPath = "/var/log/grafana-alloy.log";
            };
          };
        }
        (lib.mkIf cfg.loki.mtls.enable {
          assertions = [
            {
              assertion = lokiMtlsClient != null;
              message = "host.observability.logs.loki.mtls.clientName must reference an enabled host.observability.client.mtlsClients entry.";
            }
          ];

          sops.secrets.observabilityLokiClientCrt = {
            key = "${lokiMtlsClient.secretPrefix}/client_crt_unencrypted";
            owner = "root";
            group = "wheel";
            mode = "0400";
          };

          sops.secrets.observabilityLokiClientKey = {
            key = "${lokiMtlsClient.secretPrefix}/client_key";
            owner = "root";
            group = "wheel";
            mode = "0400";
          };
        })
      ]
    ))
  ];
}
