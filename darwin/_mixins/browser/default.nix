{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.host.userEnvironment.features.firefox;
in
{
  config = lib.mkIf (cfg.enable && cfg.makeDefault) {
    environment.systemPackages = with pkgs; [
      defaultbrowser
    ];

    system.activationScripts.userActivation.text = ''
      # Set default browser to firefox
      ${lib.getExe pkgs.defaultbrowser} firefox
    '';
  };
}
