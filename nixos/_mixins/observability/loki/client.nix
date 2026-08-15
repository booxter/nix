{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.observability;
  lokiClient = cfg.loki.client;
  lokiPkiClient = config.host.pki.clients.loki;
  lokiClientCertCredentialPath = "/run/credentials/alloy.service/loki-client.crt";
  lokiClientKeyCredentialPath = "/run/credentials/alloy.service/loki-client.key";
  lokiTlsConfig = lib.optionalString (lokiClient != null) ''
    tls_config {
      ca_file = "${lokiClient.trustedCaCertificate}"
      cert_file = "${lokiClientCertCredentialPath}"
      key_file = "${lokiClientKeyCredentialPath}"
      server_name = "${lokiClient.serverName}"
    }
  '';
  hostLabel = config.services.avahi.hostName;
in
{
  config = lib.mkIf (cfg.enable && lokiClient != null) {
    host.pki.clients.loki = {
      category = "observability";
      secretPrefix = "observability/clients/loki";
      materializations.default.restartUnits = [ "alloy.service" ];
    };
    services.alloy = {
      enable = true;
      configPath = pkgs.writeText "config.alloy" ''
                    loki.write "default" {
                      endpoint {
                        url = "${lokiClient.writeUrl}"
        ${lokiTlsConfig}
                      }
                    }

                    loki.relabel "journal" {
                      forward_to = []

                      rule {
                        source_labels = ["__journal_coredump_gid", "__journal_coredump_exe"]
                        separator     = ";"
                        regex         = "30000;/build/.*"
                        action        = "drop"
                      }

                      rule {
                        source_labels = ["__journal__hostname"]
                        target_label  = "node_hostname"
                      }

                      rule {
                        source_labels = ["__journal__systemd_unit"]
                        target_label  = "systemd_unit"
                      }

                      rule {
                        source_labels = ["__journal_priority_keyword"]
                        target_label  = "level"
                      }
                    }

                    loki.source.journal "read" {
                      forward_to    = [loki.write.default.receiver]
                      relabel_rules = loki.relabel.journal.rules
                      max_age       = "12h"
                      labels = {
                        job  = "systemd-journal",
                        host = "${hostLabel}",
                      }
                    }
      '';
    };

    systemd.services.alloy = {
      wants = [ "sops-install-secrets.service" ];
      after = [ "sops-install-secrets.service" ];
      serviceConfig.LoadCredential = [
        "loki-client.crt:${lokiPkiClient.materializations.default.certificatePath}"
        "loki-client.key:${lokiPkiClient.materializations.default.keyPath}"
      ];
    };
  };
}
