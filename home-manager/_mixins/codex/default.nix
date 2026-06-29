{
  config,
  lib,
  pkgs,
  isWork,
  ...
}:
let
  codexPkgs = import ./pkgs { inherit pkgs; };
in
{
  programs.codex = {
    enable = true;

    settings = {
      model = "gpt-5.5";
      model_reasoning_effort = "xhigh";
      personality = "pragmatic";
      approvals_reviewer = "auto_review";

      projects = {
        "${config.home.homeDirectory}/src/nix".trust_level = "trusted";
        "${config.home.homeDirectory}/src/nixpkgs".trust_level = "trusted";
        "${config.home.homeDirectory}/src/ovn-kubernetes".trust_level = "trusted";
      };

      # Avoid accidental bare-Esc interrupts until Codex has safer interrupt UX:
      # https://github.com/openai/codex/issues/12582
      # https://github.com/openai/codex/issues/14509
      tui.keymap.chat.interrupt_turn = "f12";
    }
    // lib.optionalAttrs (!isWork) {
      mcp_servers.firefox-devtools = {
        command = lib.getExe pkgs.firefox-devtools-mcp;
        args = [
          "--profile-path"
          "${config.xdg.dataHome}/firefox-devtools-mcp"
          "--accept-insecure-certs"
          "--viewport"
          "1440x1000"
        ];
      };
    };

    rules.default = ''
      prefix_rule(
          pattern = ["nix", "eval"],
          decision = "allow",
          justification = "Nix evaluation is a routine read-only repository check.",
          match = [
              "nix eval .#darwinConfigurations.mair.config.system.stateVersion",
              "nix eval --raw .#nixosConfigurations.fana.config.system.build.toplevel.drvPath",
          ],
          not_match = [
              "nix build .#darwinConfigurations.mair.system",
          ],
      )

      prefix_rule(
          pattern = ["nix", "build"],
          decision = "allow",
          justification = "Nix builds are routine repository verification commands.",
          match = [
              "nix build .#darwinConfigurations.mair.system",
              "nix build .#nixosConfigurations.fana.config.system.build.toplevel",
          ],
          not_match = [
              "nix eval .#darwinConfigurations.mair.config.system.stateVersion",
          ],
      )

      prefix_rule(
          pattern = ["rg"],
          decision = "allow",
          justification = "Ripgrep searches are routine read-only repository inspection commands.",
          match = [
              "rg -n codex home-manager",
              "rg --files",
          ],
      )
    '';
  };

  home.file = {
    ".codex/config.toml".force = true;
    ".codex/rules/default.rules".force = true;
  };

  home.packages = lib.optionals (!isWork) [
    codexPkgs.codex-usage-status
    codexPkgs.codex-rate-limit-reset-credits
  ];
}
