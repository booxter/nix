{
  config,
  hostInventory,
  lib,
  pkgs,
  ...
}:
let
  realmLlm = hostInventory.realms.${config.host.realm}.services.llm or null;
  providerHost = if realmLlm == null then null else realmLlm.providerHost;
  cfg = config.host.llm.provider;
  service = if realmLlm == null then null else hostInventory.servicesById.${realmLlm.serviceId};
  gpu = config.host.gpu;
  ollamaPackage =
    if gpu != null && gpu.computeBackend == "rocm" then pkgs.ollama-rocm else pkgs.ollama;
  nodeExporterTextfileDir = "/var/lib/prometheus-node-exporter-textfile";
  atomicFileWrites = pkgs.python3Packages.callPackage ../../../pkgs/atomic-file-writes { };
  metricsPackage = pkgs.callPackage ./packages/ollama-metrics { inherit atomicFileWrites; };
in
{
  options.host.llm.provider = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = providerHost != null && providerHost == config.networking.hostName;
      readOnly = true;
      internal = true;
      description = "Whether this host provides the realm's LLM service.";
    };

    host = lib.mkOption {
      type = with lib.types; nullOr str;
      default = providerHost;
      readOnly = true;
      internal = true;
      description = "Host that provides the LLM service for this realm.";
    };

    models = lib.mkOption {
      type = with lib.types; listOf str;
      default = if realmLlm == null then [ ] else realmLlm.models;
      readOnly = true;
      internal = true;
      description = "Models kept available by the realm LLM provider.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = service.owner == cfg.host;
        message = "The realm LLM endpoint must be owned by its provider host.";
      }
    ];

    services.ollama = {
      enable = true;
      package = ollamaPackage;
      host = "127.0.0.1";
      port = 11434;
      loadModels = cfg.models;
      syncModels = true;
      environmentVariables.OLLAMA_KEEP_ALIVE = "30m";
    };

    systemd.services.ollama-metrics = {
      description = "Collect Ollama state metrics for Prometheus";
      wants = [ "ollama.service" ];
      after = [ "ollama.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe metricsPackage} --base-url http://127.0.0.1:${toString config.services.ollama.port} --output ${nodeExporterTextfileDir}/ollama.prom";
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

    host.internalHttps.services.${realmLlm.serviceId} = {
      enable = true;
      upstream = "http://127.0.0.1:${toString config.services.ollama.port}";
      mtls.enable = true;
      serverAliases = [ service.displayHost ];
      localAliases = [ realmLlm.serviceId ];
      locationExtraConfig = ''
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
      '';
    };
  };
}
