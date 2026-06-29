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
  programs.codex.enable = true;

  home.packages = lib.optionals (!isWork) [
    codexPkgs.codex-usage-status
    codexPkgs.codex-rate-limit-reset-credits
  ];
}
