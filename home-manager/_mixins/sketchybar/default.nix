{ lib, pkgs, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
  cliToolsPkgs = import ../cli-tools/pkgs { inherit pkgs; };
  codexPlugin = pkgs.writeShellApplication {
    name = "sketchybar-codex";
    runtimeInputs = [
      cliToolsPkgs.codex-usage-status
      pkgs.jq
      pkgs.sketchybar
    ];
    text = builtins.readFile ./sketchybar/plugins/codex.sh;
  };
  sketchybarConfig = pkgs.runCommandLocal "sketchybar-config" { } ''
    mkdir -p "$out"
    cp -R ${./sketchybar}/. "$out/"
    chmod -R u+w "$out"
    rm -f "$out/plugins/codex.sh"
    ln -s ${lib.getExe codexPlugin} "$out/plugins/codex.sh"
  '';
in
{
  programs.sketchybar = lib.mkIf isDarwin {
    enable = true;
    config = {
      source = sketchybarConfig;
      recursive = true;
    };
    service.enable = false;
    extraPackages = with pkgs; [
      aerospace
      gnugrep
      curl
      jq
    ];
  };
}
