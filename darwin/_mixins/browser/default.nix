{ lib, pkgs, ... }: {
  environment.systemPackages = with pkgs; [
    defaultbrowser
  ];

  system.activationScripts.postUserActivation.text = ''
    # Set default browser to firefox
    ${lib.getExe pkgs.defaultbrowser} firefox
  '';
}
