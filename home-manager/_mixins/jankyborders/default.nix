{ lib, pkgs, ... }:
let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;
in
{
  services.jankyborders = lib.mkIf isDarwin {
    enable = true;
    settings = {
      active_color = "glow\\(0xffFF0000\\)";
      inactive_color = "0xff000000";
      hidpi = "on";
    };
  };
}
