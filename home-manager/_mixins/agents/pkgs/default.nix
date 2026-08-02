{ pkgs }:
rec {
  codex-mcp-init = pkgs.writeShellApplication {
    name = "codex-mcp-init";
    runtimeInputs = with pkgs; [
      jq
    ];
    text = builtins.readFile ./codex-mcp-init.sh;
  };

  codex-usage-status = pkgs.callPackage ./codex-usage-status { };

  codex-rate-limit-reset-credits = pkgs.writeShellApplication {
    name = "codex-rate-limit-reset-credits";
    runtimeInputs = with pkgs; [
      curl
      jq
    ];
    text = builtins.readFile ./codex-rate-limit-reset-credits.sh;
  };

  codex-warmer = pkgs.callPackage ./codex-warmer {
    codexUsageStatus = codex-usage-status;
  };

  codex-work-usage-status = pkgs.writeShellApplication {
    name = "codex-work-usage-status";
    runtimeInputs = with pkgs; [
      curl
      jq
    ];
    text = builtins.readFile ./codex-work-usage-status.sh;
  };
}
