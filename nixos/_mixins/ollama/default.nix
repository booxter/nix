{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.ollama;
  textfileDir = config.host.observability.nodeExporter.textfile.directories.default;
  ollamaMetrics = pkgs.callPackage ./metrics { };
in
{
  options.host.ollama = lib.mkOption {
    type = lib.types.nullOr (
      lib.types.submodule {
        options.contextLength = lib.mkOption {
          type = lib.types.nullOr lib.types.ints.positive;
          default = null;
          description = "Default context length allocated by Ollama runners.";
        };

        options.models = lib.mkOption {
          type = lib.types.attrsOf (
            lib.types.submodule {
              options.capabilities = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.enum [
                    "text"
                    "vision"
                  ]
                );
                default = [ "text" ];
                description = "LLM capabilities advertised by this model.";
              };
            }
          );
          default = { };
          description = "Ollama models served by this host.";
        };
      }
    );
    default = null;
    description = "Ollama server configuration.";
  };

  config = lib.mkIf (cfg != null) {
    host.observability.systemd.excludedUnits = [ "ollama-model-loader.service" ];

    host.web.services.ollama = {
      upstream = "http://127.0.0.1:${toString config.services.ollama.port}";
      internal = {
        localAliases = [ "ollama" ];
        locationExtraConfig = ''
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
        '';
      };
    };

    services.ollama = {
      enable = true;
      package = pkgs.ollama-rocm;
      host = "127.0.0.1";
      port = 11434;
      loadModels = builtins.attrNames cfg.models;
      syncModels = true;
      environmentVariables = {
        OLLAMA_KEEP_ALIVE = "30m";
      }
      // lib.optionalAttrs (cfg.contextLength != null) {
        OLLAMA_CONTEXT_LENGTH = toString cfg.contextLength;
      };
    };

    host.observability.nodeExporter.textfile.periodicProducers.ollama-metrics = {
      description = "Collect Ollama state metrics for Prometheus";
      wants = [ "ollama.service" ];
      after = [ "ollama.service" ];
      command = [
        (lib.getExe ollamaMetrics)
        "--base-url"
        "http://127.0.0.1:${toString config.services.ollama.port}"
        "--output"
        "${textfileDir}/ollama.prom"
      ];
      interval = "1m";
      onBootSec = "2m";
      accuracySec = "10s";
      addressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];
    };
  };
}
