{ config, lib, ... }:
let
  cfg = config.host.userEnvironment;
in
{
  options.host.userEnvironment = {
    roles.developer.enable = lib.mkEnableOption "interactive software development environment";

    features.codex = {
      enable = lib.mkEnableOption "Codex coding agent";

      usageStatus.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to provide standard Codex usage status integration.";
      };

      resetCredits.enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to provide the Codex reset-credits utility.";
      };

      workUsageStatus.enable = lib.mkEnableOption "work Codex usage status integration";

      warmer.enable = lib.mkEnableOption "periodic Codex usage-window warmer";
    };
  };

  config = lib.mkIf cfg.roles.developer.enable {
    host.userEnvironment.features.codex.enable = lib.mkDefault true;
  };
}
