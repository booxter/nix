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
      hide_window_decorations = "titlebar-only";
      # Make the focused split obvious even when the cursor is hard to spot.
      window_border_width = "2pt";
      active_border_color = "#ff5a00";
      inactive_border_color = "#30323d";
      inactive_text_alpha = "0.85";
    };
    keybindings = {
      "cmd+с" = "copy_to_clipboard";
      "cmd+м" = "paste_from_clipboard";
      "cmd+ч" = "cut_to_clipboard";
    };
  };
  home.file = {
    ".config/kitty/open-actions.conf".source = ./kitty-open-actions.conf;
  };
}
