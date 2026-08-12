{ lib, ... }:
{
  imports = [
    ./codex
    ./opencode
  ];

  options.host.hm.dev = {
    codex.enable = lib.mkEnableOption "Codex coding agent";
    opencode.enable = lib.mkEnableOption "OpenCode coding agent";
  };
}
