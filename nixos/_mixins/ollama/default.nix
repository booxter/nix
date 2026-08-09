{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.ollama;
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  ollamaMetrics = pkgs.callPackage ./metrics { };
  ollamaService = hostInventory.servicesById.ollama;
in
{
  options.host.ollama = {
    enable = lib.mkEnableOption "Ollama server";
    enableMetrics = lib.mkEnableOption "Ollama Prometheus metrics collector";
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.enableMetrics || cfg.enable;
          message = "host.ollama.enableMetrics requires host.ollama.enable";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      host.internalHttps.services.ollama = {
        enable = true;
        upstream = "http://127.0.0.1:${toString config.services.ollama.port}";
        mtls.enable = true;
        serverAliases = [ ollamaService.displayHost ];
        localAliases = [ "ollama" ];
        locationExtraConfig = ''
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
        '';
      };

      services.ollama = {
        enable = true;
        package = pkgs.ollama-rocm;
        host = "127.0.0.1";
        port = 11434;
        loadModels = [
          "gemma4:31b"
          "granite4:32b-a9b-h"
          "nemotron-cascade-2:30b"
          "nomic-embed-text"
          "qwen3-next:80b"
          "qwen3-vl:8b-instruct"
        ];
        syncModels = true;
        environmentVariables.OLLAMA_KEEP_ALIVE = "30m";
      };
    })
    (lib.mkIf cfg.enableMetrics {
      systemd.services.ollama-metrics = {
        description = "Collect Ollama state metrics for Prometheus";
        wants = [ "ollama.service" ];
        after = [ "ollama.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${lib.getExe ollamaMetrics} --base-url http://127.0.0.1:${toString config.services.ollama.port} --output ${nodeExporterTextfileDir}/ollama.prom";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ nodeExporterTextfileDir ];
          RestrictAddressFamilies = [
            "AF_UNIX"
            "AF_INET"
            "AF_INET6"
          ];
          RestrictRealtime = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
        };
      };

      systemd.timers.ollama-metrics = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "2m";
          OnUnitActiveSec = "1m";
          AccuracySec = "10s";
        };
      };

      systemd.tmpfiles.rules = [
        "d ${nodeExporterTextfileDir} 0755 root root - -"
      ];
    })
  ];
}
