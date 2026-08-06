pkgs:
pkgs.writeShellApplication {
  name = "formatter";
  runtimeInputs = with pkgs; [
    coreutils
    deadnix
    nixfmt-tree
    shellcheck
    ruff
    prettier
    eslint
    jq
    mbake
    actionlint
    markdownlint-cli2
    git
    findutils
  ];
  text = builtins.readFile ./formatter.sh;
}
