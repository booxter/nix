{
  enable = true;
  onActivation.autoUpdate = false;
  brews = [
    "openssh"
    {
      name = "svim"; # SketchyVim
      start_service = true;
      restart_service = true;
    }
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
    "todoist"
    "wireshark-chmodbpf" # TODO: find a flake
  ];
  taps = [
    "FelixKratz/formulae" # SketchyVim
  ];
}
