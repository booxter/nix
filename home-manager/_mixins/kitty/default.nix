{ ... }:
{
  programs.kitty = {
    enable = true;
    shellIntegration.enableZshIntegration = true;
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
      inactive_text_alpha = "0.65";
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
