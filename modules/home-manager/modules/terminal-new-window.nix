{ pkgs, ... }: {
  executable = true;
  text = ''
  #!${pkgs.zsh}/bin/zsh
  #
  # Required parameters:
  # @raycast.schemaVersion 1
  # @raycast.title Terminal New Window
  # @raycast.mode silent

  # Optional parameters:
  # @raycast.icon 🤖

  # Documentation:
  # @raycast.description Create new window in preferred Terminal
  # @raycast.author Ihar Hrachyshka

  # ${pkgs.alacritty}/bin/alacritty msg create-window > /dev/null 2>&1 || ${pkgs.alacritty}/bin/alacritty

  # --single-instance doesn't play well with amethyst (it doesn't recognize consequent windows)
  # ${pkgs.kitty}/bin/kitty --single-instance

  ${pkgs.kitty}/bin/kitty
  '';
}
