{ lib, ... }:
let
  usageAccountOption =
    agent:
    lib.mkOption {
      type = lib.types.enum [
        "personal"
        "corporate"
      ];
      default = "personal";
      description = "${agent} account type used for usage accounting.";
    };
in
{
  imports = [
    ./mcp-options.nix
    ./claude
    ./codex
    ./opencode
  ];

  options.host.hm.dev = {
    claude = {
      enable = lib.mkEnableOption "Claude coding agent";
      usage.account = usageAccountOption "Claude";
    };

    codex = {
      enable = lib.mkEnableOption "Codex coding agent";
      usage.account = usageAccountOption "Codex";
    };

    opencode.enable = lib.mkEnableOption "OpenCode coding agent";
  };
}
