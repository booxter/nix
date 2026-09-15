{ lib, pkgs }:
{
  repair.controller = {
    enable = lib.mkEnableOption "scheduled Radarr repair controller";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.radarr-repair;
      description = "Radarr repair controller package.";
    };
    downloadClients = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = [ ];
      description = "Registered download clients inspected by the controller.";
    };
    interval = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "15m";
      description = "Delay between completed controller runs.";
    };
    stabilization = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "15m";
      description = "Minimum age of unchanged import-pending evidence before repair.";
    };
    metricsDirectory = lib.mkOption {
      type = lib.types.strMatching "^/.+";
      default = "/var/lib/prometheus-node-exporter-textfile/radarr-repair";
      readOnly = true;
      description = "Directory containing controller Prometheus textfile metrics.";
    };
    apply = {
      enable = lib.mkEnableOption "automatic application of Radarr repairs";
      allowedActions = lib.mkOption {
        type =
          with lib.types;
          listOf (enum [
            "join_parts_v1"
            "manual_import_file_v1"
          ]);
        default = [ ];
        description = "Repair actions the automatic controller may apply.";
      };
      allowedDownloadClients = lib.mkOption {
        type =
          with lib.types;
          listOf (enum [
            "transmission"
            "sabnzbd"
          ]);
        default = [ ];
        description = "Download clients whose cases the automatic controller may repair.";
      };
    };
  };

  repair.worker = {
    enable = lib.mkEnableOption "isolated Radarr repair media probe worker";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.radarr-repair-worker;
      description = "Radarr repair worker package.";
    };
    socketPath = lib.mkOption {
      type = lib.types.strMatching "^/.+";
      default = "/run/radarr-repair-worker/worker.sock";
      readOnly = true;
      description = "Local media probe worker socket.";
    };
    clientGroup = lib.mkOption {
      type = lib.types.str;
      default = "radarr-repair-worker-clients";
      readOnly = true;
      description = "Group allowed to call the media probe worker.";
    };
    roots = lib.mkOption {
      type = with lib.types; attrsOf (strMatching "^/.+");
      default = { };
      description = "Media roots exposed to the worker by opaque identifier.";
    };
    writableRoots = lib.mkOption {
      type = with lib.types; listOf nonEmptyStr;
      default = [ ];
      description = "Worker root identifiers that permit staged media writes.";
    };
    probeTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 30;
      description = "Maximum duration of one media probe.";
    };
    joinTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1800;
      description = "Maximum duration of one staged join request.";
    };
    maxConcurrent = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Maximum number of concurrent media probes.";
    };
  };

  repair.planner = {
    enable = lib.mkEnableOption "agentic Radarr repair planning service";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.radarr-repair-planner;
      description = "Radarr repair planner package.";
    };
    socketPath = lib.mkOption {
      type = lib.types.strMatching "^/.+";
      default = "/run/radarr-repair-planner.sock";
      readOnly = true;
      description = "Local planner API socket.";
    };
    clientGroup = lib.mkOption {
      type = lib.types.str;
      default = "radarr-repair-planner-clients";
      readOnly = true;
      description = "Group allowed to call the local planner API.";
    };
    model = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "openai/gpt-5.6-sol";
      description = "OpenRouter model identifier.";
    };
    provider = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "OpenAI";
      description = "Required OpenRouter provider.";
    };
    outputTokens = lib.mkOption {
      type = lib.types.ints.positive;
      default = 4096;
      description = "Maximum model output tokens per attempt.";
    };
    reasoningEffort = lib.mkOption {
      type = lib.types.enum [
        "none"
        "minimal"
        "low"
        "medium"
        "high"
        "xhigh"
        "max"
      ];
      default = "high";
      description = "OpenRouter reasoning effort.";
    };
    attemptTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Timeout for each model attempt.";
    };
    planningTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1220;
      description = "Timeout for the complete bounded planning graph.";
    };
  };
}
