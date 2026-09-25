{ lib, pkgs }:
{

  review = {
    enable = lib.mkEnableOption "read-only Servarr repair review inbox";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.media-repair-review;
      description = "Media repair review frontend package.";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 8790;
      description = "Loopback port for the repair review frontend.";
    };
    stateDirectory = lib.mkOption {
      type = lib.types.strMatching "^/.+";
      default = "/var/lib/media-repair-review";
      readOnly = true;
      description = "Shared root containing sanitized controller review snapshots.";
    };
    writerGroup = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "media-repair-review";
      readOnly = true;
      description = "Group allowed to read sanitized controller review snapshots.";
    };
  };

  worker = {
    enable = lib.mkEnableOption "isolated media repair worker";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.media-repair-worker;
      description = "Shared media repair worker package.";
    };
    socketPath = lib.mkOption {
      type = lib.types.strMatching "^/.+";
      default = "/run/media-repair-worker/worker.sock";
      readOnly = true;
      description = "Local media repair worker socket.";
    };
    clientGroup = lib.mkOption {
      type = lib.types.str;
      default = "media-repair-worker-clients";
      readOnly = true;
      description = "Group allowed to call the media repair worker.";
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
      description = "Maximum duration of one staged media operation.";
    };
    maxConcurrent = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Maximum number of concurrent media operations.";
    };
  };

  planner = {
    enable = lib.mkEnableOption "shared Servarr repair planning service";
    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.media-repair-planner;
      description = "Shared Servarr repair planner package.";
    };
    socketPath = lib.mkOption {
      type = lib.types.strMatching "^/.+";
      default = "/run/media-repair-planner.sock";
      readOnly = true;
      description = "Local repair planner API socket.";
    };
    clientGroup = lib.mkOption {
      type = lib.types.str;
      default = "media-repair-planner-clients";
      readOnly = true;
      description = "Group allowed to call the local repair planner API.";
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
      description = "Timeout for complete bounded planning.";
    };
  };
}
