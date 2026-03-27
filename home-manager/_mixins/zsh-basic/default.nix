{ ... }:
{
  programs.zsh = {
    enable = true;
    defaultKeymap = "viins";
    enableCompletion = false;

    initContent = ''
      bindkey "^R" history-incremental-search-backward
    '';

    shellAliases = {
      # Beautify ls output.
      ll = "ls --hyperlink=auto --color=auto -Fal";
      ls = "ls --hyperlink=auto --color=auto -F";

      view = "vim -R";
    };
  };
}
