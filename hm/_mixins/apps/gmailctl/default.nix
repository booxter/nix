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
  imports = [ ./warmer.nix ];

  options.host.hm.gmailctl = {
    enable = lib.mkEnableOption "gmailctl";
    warmer.enable = lib.mkEnableOption "periodic gmailctl OAuth token warmer";
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = !cfg.warmer.enable || cfg.enable;
          message = "host.hm.gmailctl.warmer requires host.hm.gmailctl";
        }
      ];
    }
    (lib.mkIf cfg.enable {
      home.packages = [
        pkgs.gmailctl
      ];
    })
  ];
}
