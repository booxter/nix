{ pkgs }:
rec {
  codex-mcp-init = pkgs.writeShellApplication {
    name = "codex-mcp-init";
    runtimeInputs = with pkgs; [
      jq
    ];
    text = builtins.readFile ./codex-mcp-init.sh;
  };

  codex-usage-status = pkgs.callPackage ./codex-tools { };

  codex-rate-limit-reset-credits = codex-usage-status;

  codex-warmer = codex-usage-status;

  codex-work-usage-status = codex-usage-status;
}
