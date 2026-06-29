{
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
      # Avoid accidental bare-Esc interrupts until Codex has safer interrupt UX:
      # https://github.com/openai/codex/issues/12582
      # https://github.com/openai/codex/issues/14509
      tui.keymap.chat.interrupt_turn = "f12";
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

  home.packages = lib.optionals (!isWork) [
    codexPkgs.codex-usage-status
    codexPkgs.codex-rate-limit-reset-credits
  ];
}
