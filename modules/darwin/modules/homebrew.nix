{
  enable = true;
  onActivation.autoUpdate = false;
  brews = [
    "openssh"
    "cfergeau/crc/vfkit" # for podman machine
  ];
  casks = [
    "amethyst"
    "chatgpt"
    "thunderbird"
    {
      name = "firefox";
      args = {
        appdir = "~/Applications";
        no_quarantine = true;
      };
    }
  ];
  taps = [
    "cfergeau/crc" # vfkit
  ];
}
