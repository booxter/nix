{ lib, pkgs, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  cliToolsPkgs = import ../cli-tools/pkgs { inherit pkgs; };
in
{
  programs.sketchybar = lib.mkIf isDarwin {
    enable = true;
    config = {
      source = ./sketchybar;
      recursive = true;
    };
    service.enable = false;
    extraPackages = with pkgs; [
      aerospace
      gnugrep
      curl
      jq
      cliToolsPkgs.codex-usage-status
    ];
  };
}
