{ pkgs, ... }: {
  home.packages = with pkgs; [
    telegram-desktop
  ];
  home.file = {
    # TODO: configure telegram for other platforms too (use conditional paths?)
    "Library/Application Support/Telegram Desktop/tdata/shortcuts-custom.json".source = ../dotfiles/telegram-desktop-shortcuts.json;
  };
}
