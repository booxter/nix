{
  config,
  lib,
  outputs,
  pkgs,
  ...
}:
let
  cfg = config.host.observability;
  lokiCfg = cfg.loki;
  model = import ../../../../common/_mixins/observability/loki-model.nix {
    inherit config lib outputs;
  };
  realmLoki =
    if model.server == null then
      {
        writeUrl = null;
        mtls = false;
      }
    else
      model.server;
  enabledPkiClients = lib.filterAttrs (
    _: client: client.enable && client.category == "observability"
  ) config.host.pki.clients;
  lokiClientCertCredentialPath = "/run/credentials/alloy.service/loki-client.crt";
  lokiClientKeyCredentialPath = "/run/credentials/alloy.service/loki-client.key";
  lokiMtlsClient =
    if lokiCfg.mtls.enable && builtins.hasAttr lokiCfg.mtls.clientName enabledPkiClients then
      enabledPkiClients.${lokiCfg.mtls.clientName}
    else
      null;
  lokiTlsConfig = lib.optionalString lokiCfg.mtls.enable ''
    tls_config {
      ca_file = "${lokiCfg.mtls.trustedCaCertificate}"
      cert_file = "${lokiClientCertCredentialPath}"
      key_file = "${lokiClientKeyCredentialPath}"
      server_name = "${lokiCfg.mtls.serverName}"
    }
  '';
  hostLabel = config.services.avahi.hostName;
in
{
  options.host.observability.loki = {
    writeUrl = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      description = "Loki push endpoint URL for journal log shipping.";
    };

    mtls = {
      enable = lib.mkEnableOption "mTLS authentication for Loki log shipping";

      clientName = lib.mkOption {
        type = lib.types.str;
        default = "loki";
        description = "Name of the host.pki.clients entry used for Loki writes.";
      };

      serverName = lib.mkOption {
        type = lib.types.str;
        default = "loki.${config.host.network.lanDomain}";
        description = "TLS server name used for Loki writes.";
      };

      trustedCaCertificate = lib.mkOption {
        type = lib.types.path;
        default = config.host.pki.rootCaCertificate;
        description = "CA bundle used to verify the Loki writer endpoint.";
      };
    };
  };

  config = lib.mkMerge [
    {
      host.observability.loki = {
        writeUrl = lib.mkDefault realmLoki.writeUrl;
        mtls.enable = lib.mkDefault realmLoki.mtls;
      };
      host.pki.clients.loki = {
        enable = lib.mkDefault (cfg.enable && lokiCfg.writeUrl != null && lokiCfg.mtls.enable);
        category = "observability";
        secretPrefix = "observability/clients/loki";
        materializations.default.restartUnits = [ "alloy.service" ];
      };
    }
    (lib.mkIf cfg.enable (
      lib.mkMerge [
        {
          services.alloy = lib.mkIf (lokiCfg.writeUrl != null) {
            enable = true;
            configPath = pkgs.writeText "config.alloy" ''
                          loki.write "default" {
                            endpoint {
                              url = "${lokiCfg.writeUrl}"
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
        }
        (lib.mkIf (lokiCfg.writeUrl != null && lokiCfg.mtls.enable) {
          assertions = [
            {
              assertion = lokiMtlsClient != null;
              message = "host.observability.loki.mtls.clientName must reference an enabled observability-category host.pki.clients entry.";
            }
          ];

          systemd.services.alloy = {
            wants = [ "sops-install-secrets.service" ];
            after = [ "sops-install-secrets.service" ];
            serviceConfig.LoadCredential = [
              "loki-client.crt:${
                config.sops.secrets.${lokiMtlsClient.materializations.default.certificateSecretName}.path
              }"
              "loki-client.key:${
                config.sops.secrets.${lokiMtlsClient.materializations.default.keySecretName}.path
              }"
            ];
          };
        })
      ]
    ))
  ];
}
