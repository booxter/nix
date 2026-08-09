{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./firefox.nix ];

  config = lib.mkIf (config.host.userProfile == "personal") {
    environment.systemPackages = with pkgs; [
      defaultbrowser
    ];

    system.activationScripts.userActivation.text = ''
      # Set default browser to firefox
      ${lib.getExe pkgs.defaultbrowser} firefox
    '';
  };
}
