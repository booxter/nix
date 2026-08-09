{
  config,
  framePkgs,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  ollamaService = hostInventory.servicesById.ollama;
in
{
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
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "30m";
    };
  };

  systemd.services.frame-ollama-metrics = {
    description = "Collect Ollama state metrics for Prometheus";
    wants = [ "ollama.service" ];
    after = [ "ollama.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe' framePkgs.frame-observability "frame-ollama-metrics"} --base-url http://127.0.0.1:${toString config.services.ollama.port} --output ${nodeExporterTextfileDir}/frame-ollama.prom";
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

  systemd.timers.frame-ollama-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "1m";
      AccuracySec = "10s";
    };
  };
}
