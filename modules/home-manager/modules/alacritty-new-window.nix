{ pkgs, ... }: {
  executable = true;
  text = ''
  #!${pkgs.zsh}/bin/zsh
  #
  # Required parameters:
  # @raycast.schemaVersion 1
  # @raycast.title Alacritty New Window
  # @raycast.mode silent

  # Optional parameters:
  # @raycast.icon 🤖

  # Documentation:
  # @raycast.description Create new window in Alacritty
  # @raycast.author Ihar Hrachyshka

  ${pkgs.alacritty}/bin/alacritty msg create-window > /dev/null 2>&1 || ${pkgs.alacritty}/bin/alacritty
  '';
}
