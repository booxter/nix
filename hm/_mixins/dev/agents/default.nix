{ lib, ... }:
{
  imports = [
    ./codex
    ./opencode
  ];

  options.host.hm.dev = {
    codex = {
      enable = lib.mkEnableOption "Codex coding agent";

      usage = {
        account = lib.mkOption {
          type = lib.types.enum [
            "personal"
            "corporate"
          ];
          default = "personal";
          description = "Codex account type used for usage accounting.";
        };

        warmer.enable = lib.mkEnableOption "periodic Codex usage-window warmer";
      };
    };

    opencode.enable = lib.mkEnableOption "OpenCode coding agent";
  };
}
