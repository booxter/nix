{
  enable = true;
  onActivation.autoUpdate = false;
  brews = [
    "dyld-shared-cache-extractor"
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
    "todoist"
    "wireshark-chmodbpf" # TODO: find a flake
  ];
  taps = [
    "FelixKratz/formulae" # SketchyVim
    "keith/formulae" # dyld-shared-cache-extractor
  ];
}
