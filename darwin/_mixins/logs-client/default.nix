{
  config,
  lib,
  pkgs,
  ...
}:
let
  lokiClient = config.host.observability.loki.client;
  enable = config.host.observability.enable;
  stateDir = "/var/lib/grafana-alloy";
  hostLabel = config.networking.hostName;
  fileGlobs = [
    "/var/log/*.log"
    "/var/log/nix-darwin/*.log"
    "/private/var/lib/prometheus-node-exporter/*.log"
  ];
  renderLabelMap =
    labels:
    "{ ${
      lib.concatStringsSep ", " (
        lib.mapAttrsToList (name: value: "${builtins.toJSON name} = ${builtins.toJSON value}") labels
      )
    } }";
  logTargets = map (path: {
    "__path__" = path;
    job = "darwin-file-log";
    host = hostLabel;
  }) fileGlobs;
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
  config = lib.mkIf (enable && lokiClient != null) {
    host.pki.clients.loki = {
      category = "observability";
      secretPrefix = "observability/clients/loki";
      materializations.default.group = "wheel";
    };

    system.activationScripts.postActivation.text = lib.mkAfter ''
      mkdir -p ${stateDir}
      chmod 0755 ${stateDir}
    '';

    launchd.daemons.grafana-alloy-logs = {
      command = lib.escapeShellArgs [
        (lib.getExe pkgs.grafana-alloy)
        "run"
        "--server.http.listen-addr=127.0.0.1:12345"
        "--storage.path=${stateDir}"
        alloyConfig
      ];
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        WorkingDirectory = stateDir;
        EnvironmentVariables = {
          HOME = "/var/root";
        };
        ProcessType = "Background";
        StandardOutPath = "/var/log/nix-darwin/grafana-alloy.log";
        StandardErrorPath = "/var/log/nix-darwin/grafana-alloy.log";
      };
    };
  };
}
