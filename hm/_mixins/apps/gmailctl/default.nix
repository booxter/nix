{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.hm.gmailctl;
in
{
  options.host.hm.gmailctl.enable = lib.mkEnableOption "gmailctl";

  config = lib.mkIf cfg.enable {
    home.packages = [
      pkgs.gmailctl
    ];
  };
}
