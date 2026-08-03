{
  pkgs,
  codex ? pkgs.codex,
}:
rec {
  codex-usage-status = pkgs.callPackage ./codex-tools { };

  codex-mcp-init = pkgs.callPackage ./codex-mcp-init { inherit codex; };

  codex-rate-limit-reset-credits = codex-usage-status;

  codex-warmer = codex-usage-status;

  codex-work-usage-status = codex-usage-status;
}
