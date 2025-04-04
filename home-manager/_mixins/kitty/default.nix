{ ... }:
{
  programs.kitty = {
    enable = true;
    themeFile = "cherry-midnight";
    shellIntegration.enableZshIntegration = true;
    font = {
      name = "MesloLGS Nerd Font Mono";
      size = 14;
    };
    settings = {
      macos_quit_when_last_window_closed = true;
      close_on_child_death = true;
      enable_audio_bell = false;
      mouse_hide_wait = 0;
      strip_trailing_spaces = "always";
      scrollback_pager = "page -t man";
      scrollback_lines = 100000;
    };
  };
  home.file = {
    ".config/kitty/open-actions.conf".source = ./kitty-open-actions.conf;
  };
}
