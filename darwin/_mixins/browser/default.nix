{
  config,
  lib,
  pkgs,
  ...
}:
let
  appsCfg = config.host.userEnvironment.features.apps;
  cfg = appsCfg.firefox;
in
{
  config = lib.mkIf (appsCfg.enable && cfg.enable && cfg.makeDefault) {
    environment.systemPackages = with pkgs; [
      defaultbrowser
    ];

    system.activationScripts.userActivation.text = ''
      # Set default browser to firefox
      ${lib.getExe pkgs.defaultbrowser} firefox
    '';
  };
}
