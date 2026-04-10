{ pkgs, username, ... }:
{
  services = {
    xserver.enable = true;
    displayManager.autoLogin = {
      enable = true;
      user = username;
    };
    xserver.displayManager.lightdm = {
      enable = true;
      greeter.enable = false;
    };
    xserver.desktopManager.xfce.enable = true;
  };

  services.displayManager.defaultSession = "xfce";

  programs.dconf.enable = true;
  programs.xfconf.enable = true;

  # Keep the image basic and let Xfce provide the main desktop experience.
  environment.systemPackages = with pkgs; [
    thunar
  ];
}
