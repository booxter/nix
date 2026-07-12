{ pkgs }:
rec {
  codex-usage-status = pkgs.writeShellApplication {
    name = "codex-usage-status";
    runtimeInputs = with pkgs; [
      curl
      jq
    ];
    text = builtins.readFile ./codex-usage-status.sh;
  };

  codex-rate-limit-reset-credits = pkgs.writeShellApplication {
    name = "codex-rate-limit-reset-credits";
    runtimeInputs = with pkgs; [
      curl
      jq
    ];
    text = builtins.readFile ./codex-rate-limit-reset-credits.sh;
  };

  codex-warmer = pkgs.writeShellApplication {
    name = "codex-warmer";
    runtimeInputs = with pkgs; [
      codex-usage-status
      curl
      jq
    ];
    text = builtins.readFile ./codex-warmer.sh;
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
