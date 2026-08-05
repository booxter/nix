{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ./firefox-touch-id-passkeys.nix
  ];

  config = lib.mkIf (!config.host.isWork) {
    environment.systemPackages = with pkgs; [
      defaultbrowser
    ];

    system.activationScripts.userActivation.text = ''
      # Set default browser to firefox
      ${lib.getExe pkgs.defaultbrowser} firefox
    '';
  };
}
