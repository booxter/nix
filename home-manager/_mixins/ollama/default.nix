{ lib, pkgs, ... }:
let
  inherit (pkgs.stdenv) isDarwin;
in
{
  home.packages = with pkgs; [
    ollama
  ];

  services.ollama.enable = true;
  launchd.agents.ollama = lib.optionalAttrs isDarwin {
    config = {
      StandardErrorPath = "/tmp/ollama.err";
      StandardOutPath = "/tmp/ollama.out";
    };
  };
}
