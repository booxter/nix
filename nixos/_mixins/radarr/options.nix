{ lib, pkgs }:
{
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
