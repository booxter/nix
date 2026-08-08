pkgs:
pkgs.writeShellApplication {
  name = "formatter";
  runtimeInputs = with pkgs; [
    coreutils
    cargo
    deadnix
    nixfmt-tree
    shellcheck
    ruff
    rustfmt
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
