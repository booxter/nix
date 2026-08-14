{
  config,
  lib,
  pkgs,
  ...
}:
let
  username = config.host.username;
  firefoxEnabled = config.home-manager.users.${username}.host.hm.firefox.enable;
in
{
  config = lib.mkIf (config.host.userEnvironment.roles.workstation.enable && firefoxEnabled) {
    environment.systemPackages = with pkgs; [
      defaultbrowser
    ];

    system.activationScripts.userActivation.text = ''
      # Set default browser to firefox
      ${lib.getExe pkgs.defaultbrowser} firefox
    '';
  };
}
