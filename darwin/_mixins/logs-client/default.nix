{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability.logs;
  lokiClient = config.host.observability.loki.client;
  stateDir = "/var/lib/grafana-alloy";
  hostLabel = config.networking.hostName;
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
  lokiTlsConfig = lib.optionalString (lokiClient != null) ''
    tls_config {
      ca_file = "${lokiClient.trustedCaCertificate}"
      cert_file = "${config.host.pki.clients.loki.materializations.default.certificatePath}"
      key_file = "${config.host.pki.clients.loki.materializations.default.keyPath}"
      server_name = "${lokiClient.serverName}"
    }
  '';
  alloyConfig = pkgs.writeText "darwin-file-logs.alloy" ''
    loki.write "default" {
      endpoint {
        url = "${if lokiClient == null then "" else lokiClient.writeUrl}"
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

    fileGlobs = lib.mkOption {
      type = with lib.types; listOf str;
      default = [
        "/var/log/*.log"
        "/var/log/nix-darwin/*.log"
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
        enable = lib.mkDefault config.host.observability.enable;
      };

      host.pki.clients.loki = {
        enable = lib.mkDefault (cfg.enable && lokiClient != null);
        category = "observability";
        secretPrefix = "observability/clients/loki";
        materializations.default.group = "wheel";
      };
    }
    (lib.mkIf (cfg.enable && lokiClient != null) {
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
    })
  ];
}
