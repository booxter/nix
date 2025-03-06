# TODO: check module for homebrew?
{ ... }: {
  homebrew = {
    enable = true;
    onActivation.autoUpdate = true;
    brews = [
      "openssh" # it supports gss
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
    ];
    taps = [
      "FelixKratz/formulae" # SketchyVim
    ];
  };
}
