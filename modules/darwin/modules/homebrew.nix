{
  enable = true;
  onActivation.autoUpdate = false;
  brews = [ "openssh" ];
  casks = [
    "amethyst"
    "thunderbird"
    {
      name = "firefox";
      args = {
        appdir = "~/Applications";
        no_quarantine = true;
      };
    }
  ];
}
