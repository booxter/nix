{ lib, pkgs }:
{
  enable = lib.mkEnableOption "Repairr media repair daemon and inbox";
  roots = lib.mkOption {
    type = with lib.types; attrsOf (strMatching "^/.+");
    default = { };
    description = "Media roots available to the isolated repair helper.";
  };
  port = lib.mkOption {
    type = lib.types.port;
    default = 8790;
    description = "Loopback port for Repairr.";
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
