{
  pkgs,
  codex ? pkgs.codex,
}:
rec {
  codex-usage-status = pkgs.callPackage ./codex-tools { };

  codex-mcp-init = pkgs.callPackage ./codex-mcp-init { inherit codex; };

  codex-warmer = codex-usage-status;
}
