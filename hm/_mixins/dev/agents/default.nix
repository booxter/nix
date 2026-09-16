{ lib, ... }:
{
  imports = [
    ./codex
    ./opencode
  ];

  options.host.hm.dev = {
    codex = {
      enable = lib.mkEnableOption "Codex coding agent";

      usage.account = lib.mkOption {
        type = lib.types.enum [
          "personal"
          "corporate"
        ];
        default = "personal";
        description = "Codex account type used for usage accounting.";
      };
    };

    opencode.enable = lib.mkEnableOption "OpenCode coding agent";
  };
}
